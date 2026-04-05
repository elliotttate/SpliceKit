//
//  FCPBridgeSwizzle.m
//  Method swizzling infrastructure with undo capability
//

#import "FCPBridge.h"

static NSMutableDictionary<NSString *, NSValue *> *sOriginalImplementations = nil;

static void ensureStorage(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sOriginalImplementations = [NSMutableDictionary dictionary];
    });
}

IMP FCPBridge_swizzleMethod(Class cls, SEL selector, IMP newImpl) {
    ensureStorage();

    Method method = class_getInstanceMethod(cls, selector);
    if (!method) {
        NSLog(@"[FCPBridge] Swizzle FAIL: -%@ not found on %@",
              NSStringFromSelector(selector), NSStringFromClass(cls));
        return NULL;
    }

    IMP original = method_setImplementation(method, newImpl);

    NSString *key = [NSString stringWithFormat:@"%@.%@",
                     NSStringFromClass(cls), NSStringFromSelector(selector)];
    sOriginalImplementations[key] = [NSValue valueWithPointer:original];

    NSLog(@"[FCPBridge] Swizzled: -[%@ %@]",
          NSStringFromClass(cls), NSStringFromSelector(selector));
    return original;
}

BOOL FCPBridge_unswizzleMethod(Class cls, SEL selector) {
    ensureStorage();

    NSString *key = [NSString stringWithFormat:@"%@.%@",
                     NSStringFromClass(cls), NSStringFromSelector(selector)];
    NSValue *origVal = sOriginalImplementations[key];
    if (!origVal) {
        NSLog(@"[FCPBridge] Unswizzle FAIL: no original for -[%@ %@]",
              NSStringFromClass(cls), NSStringFromSelector(selector));
        return NO;
    }

    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return NO;

    method_setImplementation(method, [origVal pointerValue]);
    [sOriginalImplementations removeObjectForKey:key];

    NSLog(@"[FCPBridge] Unswizzled: -[%@ %@]",
          NSStringFromClass(cls), NSStringFromSelector(selector));
    return YES;
}
