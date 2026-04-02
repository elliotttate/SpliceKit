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
        @"viewerPinchZoom": @(FCPBridge_isViewerPinchZoomEnabled()),
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

// Swizzled -[FFAnchoredSequence defaultTransitionOverlapType]
// Original returns 1 (needs handles). We return 2 (overlap/use edge frames) when forced.
static int FCPBridge_swizzled_defaultTransitionOverlapType(id self, SEL _cmd) {
    if (sForceOverlap) {
        FCPBridge_log(@"[FreezeExtend] defaultTransitionOverlapType -> 2 (forced overlap)");
        return 2;
    }
    return ((int (*)(id, SEL))sOrigDefaultOverlapType)(self, _cmd);
}

static IMP sOrigDisplayTransitionAlert = NULL;
static NSString *sFreezeExtendPendingTransitionID = nil; // For API auto-accept

static BOOL sFreezeExtendUseSpeedRamp = NO; // Set when user clicks "Use Freeze Frames"

// Find clips at the current edit point for speed ramp application
static void FCPBridge_findClipsAtEditPoint(id timeline, id *outgoing, id *incoming) {
    *outgoing = nil;
    *incoming = nil;

    id sequence = [timeline respondsToSelector:@selector(sequence)]
        ? ((id (*)(id, SEL))objc_msgSend)(timeline, @selector(sequence)) : nil;
    if (!sequence) return;

    id primaryObj = [sequence respondsToSelector:@selector(primaryObject)]
        ? ((id (*)(id, SEL))objc_msgSend)(sequence, @selector(primaryObject)) : nil;
    if (!primaryObj) return;

    SEL erSel = NSSelectorFromString(@"effectiveRangeOfObject:");
    if (![primaryObj respondsToSelector:erSel]) return;

    // Get playhead time
    FCPBridge_CMTime ph = {0, 1, 0, 0};
    SEL ctSel = NSSelectorFromString(@"currentSequenceTime");
    if ([timeline respondsToSelector:ctSel]) {
        NSMethodSignature *sig = [timeline methodSignatureForSelector:ctSel];
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        [inv setTarget:timeline]; [inv setSelector:ctSel]; [inv invoke];
        [inv getReturnValue:&ph];
    }
    if (ph.timescale <= 0) return;

    NSArray *items = ((id (*)(id, SEL))objc_msgSend)(primaryObj, @selector(containedItems));
    if (![items isKindOfClass:[NSArray class]]) return;

    Class transCls = objc_getClass("FFAnchoredTransition");
    int64_t bestOut = INT64_MAX, bestIn = INT64_MAX;

    for (id item in items) {
        if (transCls && [item isKindOfClass:transCls]) continue;
        if ([NSStringFromClass([item class]) containsString:@"Gap"]) continue;
        @try {
            FCPBridge_CMTimeRange r = ((FCPBridge_CMTimeRange (*)(id, SEL, id))objc_msgSend)(primaryObj, erSel, item);
            int64_t s = r.start.value, e = s + r.duration.value;
            if (r.start.timescale != ph.timescale && r.start.timescale > 0) { s = r.start.value * ph.timescale / r.start.timescale; }
            if (r.duration.timescale != ph.timescale && r.duration.timescale > 0) { e = s + r.duration.value * ph.timescale / r.duration.timescale; } else { e = s + r.duration.value; }
            int64_t od = llabs(e - ph.value), id_ = llabs(s - ph.value);
            if (od < bestOut && od < ph.timescale) { bestOut = od; *outgoing = item; }
            if (id_ < bestIn && id_ < ph.timescale && item != *outgoing) { bestIn = id_; *incoming = item; }
        } @catch (NSException *ex) { continue; }
    }
}

// Apply speed ramps at clip edges, then re-apply transition
static void FCPBridge_applySpeedRampAndTransition(id timeline, NSString *transitionID) {
    FCPBridge_log(@"[FreezeExtend] Applying speed ramps at clip edges");

    id outgoing = nil, incoming = nil;
    FCPBridge_findClipsAtEditPoint(timeline, &outgoing, &incoming);

    id sequence = ((id (*)(id, SEL))objc_msgSend)(timeline, @selector(sequence));
    id primaryObj = ((id (*)(id, SEL))objc_msgSend)(sequence, @selector(primaryObject));
    SEL erSel = NSSelectorFromString(@"effectiveRangeOfObject:");
    SEL setPhSel = @selector(setPlayheadTime:);
    SEL selectSel = @selector(selectClipAtPlayhead:);

    // Get frame duration
    FCPBridge_CMTime fd = {1001, 24000, 1, 0};
    SEL fdSel = NSSelectorFromString(@"frameDuration");
    if ([sequence respondsToSelector:fdSel])
        fd = ((FCPBridge_CMTime (*)(id, SEL))objc_msgSend)(sequence, fdSel);

    // Helper: compute frame duration normalized to a target timescale
    int64_t fdNorm = fd.value;

    // --- Speed ramp to zero on outgoing clip's last frame ---
    if (outgoing && [primaryObj respondsToSelector:erSel]) {
        FCPBridge_CMTimeRange r = ((FCPBridge_CMTimeRange (*)(id, SEL, id))objc_msgSend)(primaryObj, erSel, outgoing);
        int32_t ts = r.start.timescale;
        int64_t dur = r.duration.value;
        if (r.duration.timescale != ts && r.duration.timescale > 0)
            dur = r.duration.value * ts / r.duration.timescale;
        fdNorm = fd.value;
        if (fd.timescale != ts && fd.timescale > 0)
            fdNorm = fd.value * ts / fd.timescale;

        // First: seek INSIDE the clip (midpoint) to reliably select it
        FCPBridge_CMTime midPos = r.start;
        midPos.value = r.start.value + dur / 2;
        ((void (*)(id, SEL, FCPBridge_CMTime))objc_msgSend)(timeline, setPhSel, midPos);
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        ((void (*)(id, SEL, id))objc_msgSend)(timeline, selectSel, nil);
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];

        // Now seek to the last frame for the ramp position
        FCPBridge_CMTime endPos = r.start;
        endPos.value = r.start.value + dur - fdNorm;
        FCPBridge_log(@"[FreezeExtend] Outgoing clip: selected at mid, ramp at %lld/%d", endPos.value, ts);
        ((void (*)(id, SEL, FCPBridge_CMTime))objc_msgSend)(timeline, setPhSel, endPos);
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];

        SEL rampToZeroSel = @selector(retimeSpeedRampToZero:);
        if ([timeline respondsToSelector:rampToZeroSel]) {
            FCPBridge_log(@"[FreezeExtend] Applying retimeSpeedRampToZero on outgoing clip");
            ((void (*)(id, SEL, id))objc_msgSend)(timeline, rampToZeroSel, nil);
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.15]];
        }
    }

    // --- Speed ramp from zero on incoming clip's first frame ---
    if (incoming && [primaryObj respondsToSelector:erSel]) {
        // Re-fetch since speed ramp may have shifted positions
        NSArray *items = ((id (*)(id, SEL))objc_msgSend)(primaryObj, @selector(containedItems));
        for (id item in items) {
            if (item != incoming) continue;
            @try {
                FCPBridge_CMTimeRange r = ((FCPBridge_CMTimeRange (*)(id, SEL, id))objc_msgSend)(primaryObj, erSel, item);
                int32_t ts = r.start.timescale;
                int64_t dur = r.duration.value;
                if (r.duration.timescale != ts && r.duration.timescale > 0)
                    dur = r.duration.value * ts / r.duration.timescale;
                fdNorm = fd.value;
                if (fd.timescale != ts && fd.timescale > 0)
                    fdNorm = fd.value * ts / fd.timescale;

                // First: seek INSIDE the clip (midpoint) to reliably select it
                FCPBridge_CMTime midPos = r.start;
                midPos.value = r.start.value + dur / 2;
                ((void (*)(id, SEL, FCPBridge_CMTime))objc_msgSend)(timeline, setPhSel, midPos);
                [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
                ((void (*)(id, SEL, id))objc_msgSend)(timeline, selectSel, nil);
                [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];

                // Now seek to the first frame for the ramp position
                FCPBridge_CMTime startPos = r.start;
                startPos.value += fdNorm; // One frame in to avoid edit point boundary
                FCPBridge_log(@"[FreezeExtend] Incoming clip: selected at mid, ramp at %lld/%d", startPos.value, ts);
                ((void (*)(id, SEL, FCPBridge_CMTime))objc_msgSend)(timeline, setPhSel, startPos);
                [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];

                SEL rampFromZeroSel = @selector(retimeSpeedRampFromZero:);
                if ([timeline respondsToSelector:rampFromZeroSel]) {
                    FCPBridge_log(@"[FreezeExtend] Applying retimeSpeedRampFromZero on incoming clip");
                    ((void (*)(id, SEL, id))objc_msgSend)(timeline, rampFromZeroSel, nil);
                    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.15]];
                }
            } @catch (NSException *e) { FCPBridge_log(@"[FreezeExtend] Error: %@", e.reason); }
            break;
        }
    }

    // --- Now apply the transition (with forced overlap to be safe) ---
    FCPBridge_log(@"[FreezeExtend] Re-applying transition after speed ramps");
    sForceOverlap = YES;

    Class ffEffect = objc_getClass("FFEffect");
    id originalDefault = nil;
    if (transitionID && ffEffect) {
        originalDefault = ((id (*)(id, SEL))objc_msgSend)((id)ffEffect, @selector(defaultVideoTransitionEffectID));
        [[NSUserDefaults standardUserDefaults] setObject:transitionID forKey:@"FFDefaultVideoTransition"];
    }

    // Navigate to the edit point between the ramps
    SEL prevEditSel = @selector(previousEdit:);
    if ([timeline respondsToSelector:prevEditSel]) {
        ((void (*)(id, SEL, id))objc_msgSend)(timeline, prevEditSel, nil);
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }

    SEL addSel = @selector(addTransition:);
    if ([timeline respondsToSelector:addSel])
        ((void (*)(id, SEL, id))objc_msgSend)(timeline, addSel, nil);
    else
        [[NSApplication sharedApplication] sendAction:addSel to:nil from:nil];

    sForceOverlap = NO;
    if (originalDefault)
        [[NSUserDefaults standardUserDefaults] setObject:originalDefault forKey:@"FFDefaultVideoTransition"];

    FCPBridge_log(@"[FreezeExtend] Speed ramp + transition complete");
}

// Replacement for -[FFAnchoredSequence displayTransitionAvailableMediaAlertDialog:]
static char FCPBridge_swizzled_displayTransitionAlert(id self, SEL _cmd, char *result) {
    FCPBridge_log(@"[FreezeExtend] Intercepted displayTransitionAvailableMediaAlertDialog:");

    // If API freeze_extend requested, cancel dialog — speed ramps will be applied after
    if (sFreezeExtendPendingTransitionID != nil) {
        FCPBridge_log(@"[FreezeExtend] API freeze_extend — cancelling dialog for speed ramp path");
        sFreezeExtendUseSpeedRamp = YES;
        if (result) *result = 0;
        return 1;
    }

    // Show our own alert with "Use Freeze Frames" button
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:@"There is not enough extra media beyond clip edges to create the transition."];
    [alert setInformativeText:@"\"Create Transition\" overlaps clips (may shorten project).\n\n"
        @"\"Use Freeze Frames\" adds speed ramps at clip edges to create handles, "
        @"then applies the transition."];
    [alert setAlertStyle:NSAlertStyleInformational];

    [alert addButtonWithTitle:@"Create Transition"];
    [alert addButtonWithTitle:@"Use Freeze Frames"];
    [alert addButtonWithTitle:@"Cancel"];

    NSModalResponse response = [alert runModal];

    if (response == NSAlertFirstButtonReturn) {
        // Standard overlap
        FCPBridge_log(@"[FreezeExtend] User clicked 'Create Transition'");
        if (result) *result = 1;
    } else if (response == NSAlertSecondButtonReturn) {
        // Speed ramp path — cancel this transition, apply ramps asynchronously
        FCPBridge_log(@"[FreezeExtend] User clicked 'Use Freeze Frames' — will apply speed ramps");
        sFreezeExtendUseSpeedRamp = YES;
        if (result) *result = 0; // Cancel the current transition attempt
        // Schedule speed ramp after a delay to let the call stack fully unwind
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
            if (!sFreezeExtendUseSpeedRamp) return;
            sFreezeExtendUseSpeedRamp = NO;
            id timeline = FCPBridge_getActiveTimelineModule();
            if (timeline) {
                FCPBridge_applySpeedRampAndTransition(timeline, nil);
            }
        });
    } else {
        FCPBridge_log(@"[FreezeExtend] User cancelled");
        if (result) *result = 0;
    }

    return 1;
}

// Install the swizzles (called once at startup)
void FCPBridge_installTransitionFreezeExtendSwizzle(void) {
    Class seqClass = objc_getClass("FFAnchoredSequence");
    if (!seqClass) {
        FCPBridge_log(@"[FreezeExtend] WARNING: FFAnchoredSequence class not found");
        return;
    }

    // Swizzle defaultTransitionOverlapType to allow forcing overlap mode
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
}

#pragma mark - Effect Drag as Adjustment Clip

// When a video filter is dragged from the Effects Browser to empty timeline space
// (above/below clips), create an adjustment clip with that effect instead of rejecting.
// connectAdjustmentClip: already handles getting the selected effect from the
// Effects Browser, applying it, and naming the clip after the effect.

static BOOL sEffectDropOnEmptySpace = NO;
static IMP sOrigValidateEffectsDrop = NULL;
static IMP sOrigTLKPerformDragOp = NULL;

// Swizzled -[FFAnchoredTimelineModule _validateEffectsDrop:onItem:atIndex:]
// Original rejects drops when item is the root (empty space). We accept those
// for video filters so the user gets a green "+" cursor.
static unsigned long long FCPBridge_swizzled_validateEffectsDrop(
    id self, SEL _cmd, id pasteboard, id item, long long index)
{
    unsigned long long result = ((unsigned long long (*)(id, SEL, id, id, long long))
        sOrigValidateEffectsDrop)(self, _cmd, pasteboard, item, index);

    if (result != 0) {
        // Original accepted (drop on a valid clip) — normal behavior
        sEffectDropOnEmptySpace = NO;
        return result;
    }

    // Original rejected. Check if this is a video filter over empty space.
    SEL hasTypeSel = NSSelectorFromString(@"hasEffectsWithType:");
    if (![pasteboard respondsToSelector:hasTypeSel]) {
        sEffectDropOnEmptySpace = NO;
        return 0;
    }
    BOOL hasVideoFilter = ((BOOL (*)(id, SEL, id))objc_msgSend)(
        pasteboard, hasTypeSel, @"effect.video.filter");
    if (!hasVideoFilter) {
        sEffectDropOnEmptySpace = NO;
        return 0;
    }

    // Check if item is the root item (empty timeline space)
    SEL rootSel = NSSelectorFromString(@"rootItem");
    if (![self respondsToSelector:rootSel]) {
        sEffectDropOnEmptySpace = NO;
        return 0;
    }
    id rootItem = ((id (*)(id, SEL))objc_msgSend)(self, rootSel);
    if (item != rootItem) {
        sEffectDropOnEmptySpace = NO;
        return 0;
    }

    // Accept the drop — we'll create an adjustment clip in performDragOperation:
    sEffectDropOnEmptySpace = YES;
    return 1; // NSDragOperationCopy
}

// Swizzled -[TLKTimelineView performDragOperation:]
// Intercepts the drop before FCP's normal handling. When our flag is set,
// calls connectAdjustmentClip: (creates adjustment clip with the selected effect).
static char FCPBridge_swizzled_TLKPerformDragOp(id self, SEL _cmd, id draggingInfo) {
    if (sEffectDropOnEmptySpace) {
        sEffectDropOnEmptySpace = NO;

        id timelineModule = FCPBridge_getActiveTimelineModule();
        if (timelineModule) {
            SEL adjSel = NSSelectorFromString(@"connectAdjustmentClip:");
            if ([timelineModule respondsToSelector:adjSel]) {
                FCPBridge_log(@"[EffectDrag] Creating adjustment clip from dropped effect");
                ((void (*)(id, SEL, id))objc_msgSend)(timelineModule, adjSel, nil);
                return 1; // YES — drop handled
            }
        }
        // Fallback: let FCP handle it normally
    }

    return ((char (*)(id, SEL, id))sOrigTLKPerformDragOp)(self, _cmd, draggingInfo);
}

static void FCPBridge_installEffectDragSwizzles(int attempt) {
    if (attempt >= 120) {
        FCPBridge_log(@"[EffectDrag] Classes not available after %d attempts — giving up", attempt);
        return;
    }

    Class tlmClass = objc_getClass("FFAnchoredTimelineModule");
    Class tlkClass = objc_getClass("TLKTimelineView");

    if (!tlmClass || !tlkClass) {
        // Frameworks not loaded yet — retry in 2 seconds (up to 4 minutes)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            FCPBridge_installEffectDragSwizzles(attempt + 1);
        });
        return;
    }

    // Swizzle _validateEffectsDrop:onItem:atIndex: on FFAnchoredTimelineModule
    SEL valSel = NSSelectorFromString(@"_validateEffectsDrop:onItem:atIndex:");
    Method valMethod = class_getInstanceMethod(tlmClass, valSel);
    if (valMethod) {
        sOrigValidateEffectsDrop = method_setImplementation(valMethod,
            (IMP)FCPBridge_swizzled_validateEffectsDrop);
        FCPBridge_log(@"[EffectDrag] Swizzled -[FFAnchoredTimelineModule _validateEffectsDrop:onItem:atIndex:]");
    } else {
        FCPBridge_log(@"[EffectDrag] WARNING: _validateEffectsDrop:onItem:atIndex: not found");
    }

    // Swizzle performDragOperation: on TLKTimelineView
    SEL perfSel = @selector(performDragOperation:);
    Method perfMethod = class_getInstanceMethod(tlkClass, perfSel);
    if (perfMethod) {
        sOrigTLKPerformDragOp = method_setImplementation(perfMethod,
            (IMP)FCPBridge_swizzled_TLKPerformDragOp);
        FCPBridge_log(@"[EffectDrag] Swizzled -[TLKTimelineView performDragOperation:]");
    } else {
        FCPBridge_log(@"[EffectDrag] WARNING: performDragOperation: not found on TLKTimelineView");
    }
}

void FCPBridge_installEffectDragAsAdjustmentClip(void) {
    FCPBridge_installEffectDragSwizzles(0);
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
    BOOL freezeExtend = [params[@"freezeExtend"] boolValue]; // Auto freeze-extend if not enough media

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

            // If freezeExtend is requested via API, use speed ramp path
            if (freezeExtend) {
                sFreezeExtendPendingTransitionID = [resolvedID copy];
                sFreezeExtendUseSpeedRamp = NO;
            }

            SEL addSel = @selector(addTransition:);
            if ([timelineModule respondsToSelector:addSel]) {
                ((void (*)(id, SEL, id))objc_msgSend)(timelineModule, addSel, nil);
            } else {
                [[NSApplication sharedApplication] sendAction:addSel to:nil from:nil];
            }

            // If the dialog was triggered and we chose speed ramp path, apply it now
            if (sFreezeExtendUseSpeedRamp) {
                sFreezeExtendUseSpeedRamp = NO;
                FCPBridge_applySpeedRampAndTransition(timelineModule, resolvedID);
            }

            sFreezeExtendPendingTransitionID = nil;
            sForceOverlap = NO;

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
