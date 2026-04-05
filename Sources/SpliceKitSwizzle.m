//
//  SpliceKitSwizzle.m
//  Method swizzling with rollback support.
//
//  We patch a bunch of FCP methods to add features (freeze-extend transitions,
//  adjustment clip drag, pinch-to-zoom, etc). This file provides the low-level
//  swap-and-stash machinery so each feature module doesn't reinvent it.
//
//  The key idea: every swizzle saves the original IMP keyed by "ClassName.selectorName",
//  so we can restore it later if the user toggles a feature off at runtime.
//

#import "SpliceKit.h"

// Keeps the original IMP for every method we've replaced.
// Keyed by "ClassName.selectorName" so we can reverse any swizzle cleanly.
static NSMutableDictionary<NSString *, NSValue *> *sOriginalImplementations = nil;

static void ensureStorage(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sOriginalImplementations = [NSMutableDictionary dictionary];
    });
}

IMP SpliceKit_swizzleMethod(Class cls, SEL selector, IMP newImpl) {
    ensureStorage();

    Method method = class_getInstanceMethod(cls, selector);
    if (!method) {
        NSLog(@"[SpliceKit] Swizzle FAIL: -%@ not found on %@",
              NSStringFromSelector(selector), NSStringFromClass(cls));
        return NULL;
    }

    // Atomically swap in our implementation and grab the old one
    IMP original = method_setImplementation(method, newImpl);

    NSString *key = [NSString stringWithFormat:@"%@.%@",
                     NSStringFromClass(cls), NSStringFromSelector(selector)];
    sOriginalImplementations[key] = [NSValue valueWithPointer:original];

    NSLog(@"[SpliceKit] Swizzled: -[%@ %@]",
          NSStringFromClass(cls), NSStringFromSelector(selector));
    return original;
}

BOOL SpliceKit_unswizzleMethod(Class cls, SEL selector) {
    ensureStorage();

    NSString *key = [NSString stringWithFormat:@"%@.%@",
                     NSStringFromClass(cls), NSStringFromSelector(selector)];
    NSValue *origVal = sOriginalImplementations[key];
    if (!origVal) {
        NSLog(@"[SpliceKit] Unswizzle FAIL: no original for -[%@ %@]",
              NSStringFromClass(cls), NSStringFromSelector(selector));
        return NO;
    }

    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return NO;

    // Put the original implementation back where we found it
    method_setImplementation(method, [origVal pointerValue]);
    [sOriginalImplementations removeObjectForKey:key];

    NSLog(@"[SpliceKit] Unswizzled: -[%@ %@]",
          NSStringFromClass(cls), NSStringFromSelector(selector));
    return YES;
}
