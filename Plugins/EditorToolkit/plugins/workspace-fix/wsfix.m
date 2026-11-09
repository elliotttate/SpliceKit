// workspace fix: undo splicekit's dual-timeline layout hooks that crash
// final cut when a custom workspace is applied.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
static void WSLog(NSString *s) {
    FILE *f = fopen([[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/SpliceKit/wsfix.log"] fileSystemRepresentation], "a");
    if (f) { fprintf(f, "%s %s\n", [NSDate date].description.UTF8String, s.UTF8String); fclose(f); }
}
__attribute__((constructor)) static void WSInit(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        BOOL (*unswizzle)(Class, SEL) = (BOOL(*)(Class, SEL))dlsym(RTLD_DEFAULT, "SpliceKit_unswizzleMethod");
        if (!unswizzle) { WSLog(@"no unswizzle function"); return; }
        NSArray *targets = @[
            @[@"LKModuleLayoutManager", @"newExistingRegisteredModuleMatchingLayoutDictionary:"],
            @[@"PEMediaBrowserContainerModule", @"viewMinSize"],
            @[@"FFContentBrowserModule", @"constrainWidth:"],
        ];
        for (NSArray *t in targets) {
            Class c = objc_getClass([t[0] UTF8String]);
            BOOL ok = c ? unswizzle(c, NSSelectorFromString(t[1])) : NO;
            WSLog([NSString stringWithFormat:@"unswizzle %@.%@ -> %@", t[0], t[1], ok ? @"OK" : @"not hooked/failed"]);
        }
    });
}
__attribute__((visibility("default"))) void SpliceKitPlugin_init(void *api) { (void)api; }
