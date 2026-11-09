// grade lock: clips whose name contains "lock" can't be selected on the timeline
// unless you hold the option key while clicking.
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <objc/runtime.h>

static IMP gOrig = NULL;
static NSString *GLName(id o) {
    @try {
        for (NSString *k in @[@"displayName", @"name"]) {
            if ([o respondsToSelector:NSSelectorFromString(k)]) {
                id v = [o valueForKey:k];
                if ([v isKindOfClass:[NSString class]]) return v;
            }
        }
        if ([o respondsToSelector:NSSelectorFromString(@"representedObject")]) {
            id r = [o valueForKey:@"representedObject"];
            if (r && r != o) return GLName(r);
        }
    } @catch (__unused id e) {}
    return nil;
}
static BOOL GLLocked(id o) {
    NSString *n = GLName(o);
    return n && [n rangeOfString:@"lock" options:NSCaseInsensitiveSearch].location != NSNotFound;
}
static void GLLog(NSString *s) {
    FILE *f = fopen([[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/SpliceKit/gradelock.log"] fileSystemRepresentation], "a");
    if (f) { fprintf(f, "%s\n", s.UTF8String); fclose(f); }
}
static id GLWillSelect(id self, SEL _cmd, id mgr, id objects, BOOL extend, unsigned long long *mask) {
    id result = objects;
    BOOL override = ([NSEvent modifierFlags] & NSEventModifierFlagOption) != 0;
    if (!override && [objects respondsToSelector:@selector(countByEnumeratingWithState:objects:count:)]) {
        NSMutableArray *keep = [NSMutableArray array];
        NSUInteger dropped = 0;
        for (id o in objects) { if (GLLocked(o)) dropped++; else [keep addObject:o]; }
        if (dropped) {
            GLLog([NSString stringWithFormat:@"blocked %lu locked item(s) of %@", (unsigned long)dropped, NSStringFromClass([objects class])]);
            if ([objects isKindOfClass:[NSSet class]]) result = [NSSet setWithArray:keep];
            else if ([objects isKindOfClass:[NSOrderedSet class]]) result = [NSOrderedSet orderedSetWithArray:keep];
            else result = keep;
        }
    }
    return ((id(*)(id, SEL, id, id, BOOL, unsigned long long *))gOrig)(self, _cmd, mgr, result, extend, mask);
}
__attribute__((constructor)) static void GLInit(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        Class c = objc_getClass("TLKTimelineView");
        SEL s = NSSelectorFromString(@"selectionManager:willSelectObjects:byExtendingSelection:selectionMask:");
        Method m = c ? class_getInstanceMethod(c, s) : NULL;
        if (!m) { GLLog(@"init: method not found"); return; }
        gOrig = method_setImplementation(m, (IMP)GLWillSelect);
        GLLog(@"init: grade lock active");
    });
}

// lets splicekit auto-load this at startup (its plugin loader needs this symbol)
__attribute__((visibility("default"))) void SpliceKitPlugin_init(void *api) { (void)api; }
