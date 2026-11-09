// xml clips: after any xml import, put every clip used in the imported timeline into the library browser
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
static void XL(NSString *s) {
    FILE *f = fopen([[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/SpliceKit/xmlclips.log"] fileSystemRepresentation], "a");
    if (f) { fprintf(f, "%s %s\n", [NSDate date].description.UTF8String, s.UTF8String); fclose(f); }
}
static id XO(id o, NSString *s) {
    if (!o) return nil; SEL sel = NSSelectorFromString(s);
    if (![o respondsToSelector:sel]) return nil;
    NSMethodSignature *sig = [o methodSignatureForSelector:sel];
    if (!sig || sig.numberOfArguments != 2 || strcmp(sig.methodReturnType, "@") != 0) return nil;
    return ((id(*)(id,SEL))objc_msgSend)(o, sel);
}
static void Collect(id item, NSMutableArray *out, int depth) {
    if (!item || depth > 3) return;
    [out addObject:item];
    for (id a in (NSSet *)XO(item, @"anchoredItems")) Collect(a, out, depth + 1);
}
static void AddClipsToBrowser(void) {
    @try {
        id tm = XO(XO([NSApp delegate], @"activeEditorContainer"), @"timelineModule");
        id seq = XO(tm, @"sequence");
        id prim = XO(seq, @"primaryObject");
        if (!tm || !prim) { XL(@"no timeline"); return; }
        NSMutableArray *items = [NSMutableArray array];
        for (id it in (NSArray *)XO(prim, @"containedItems")) Collect(it, items, 0);
        SEL sSet = NSSelectorFromString(@"setSelectedItems:");
        SEL sRev = NSSelectorFromString(@"_revealAncestor:addeddNewAncestorToEvent:");
        if (![tm respondsToSelector:sSet] || ![tm respondsToSelector:sRev]) { XL(@"missing selectors"); return; }
        NSArray *oldSel = XO(tm, @"selectedItems") ?: @[];
        NSMutableSet *seen = [NSMutableSet set];
        int added = 0, tried = 0;
        for (id it in items) {
            NSString *cls = NSStringFromClass([it class]);
            if (![cls containsString:@"Collection"] && ![cls containsString:@"Clip"]) continue;
            NSString *n = XO(it, @"displayName");
            if (!n || [seen containsObject:n]) continue;
            [seen addObject:n];
            tried++;
            @try {
                ((void(*)(id,SEL,id))objc_msgSend)(tm, sSet, @[it]);
                id anc = nil; BOOL isNew = NO;
                ((BOOL(*)(id,SEL,id*,BOOL*))objc_msgSend)(tm, sRev, &anc, &isNew);
                if (isNew) added++;
            } @catch (id e) { XL([NSString stringWithFormat:@"skip %@: %@", n, e]); }
        }
        ((void(*)(id,SEL,id))objc_msgSend)(tm, sSet, oldSel);
        XL([NSString stringWithFormat:@"%@: checked %d sources, added %d to browser", XO(seq, @"displayName"), tried, added]);
    } @catch (id e) { XL([NSString stringWithFormat:@"threw %@", e]); }
}
static IMP gOrigImport;
static id ActiveSeq(void) { return XO(XO(XO([NSApp delegate], @"activeEditorContainer"), @"timelineModule"), @"sequence"); }
static NSTimer *gWatch;
static __weak id gSeqBeforeImport; static BOOL gImporting;
// after an import, wait (up to 10 min) for the imported timeline to open, then fill the browser
static void WatchForNewTimeline(id before) {
    __block int ticks = 0;
    __weak id weakBefore = before;
    [gWatch invalidate];
    gWatch = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
        ticks++;
        id seq = ActiveSeq();
        if (seq && seq != weakBefore && XO(seq, @"primaryObject")) {
            [t invalidate]; gWatch = nil;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ AddClipsToBrowser(); });
        } else if (ticks > 600) { [t invalidate]; gWatch = nil; XL(@"gave up waiting for timeline"); }
    }];
}
static id h_import(id self, SEL _cmd, id *err) {
    gImporting = YES;
    id r = ((id(*)(id,SEL,id*))gOrigImport)(self, _cmd, err);
    XL(@"xml import finished, waiting for timeline");
    dispatch_async(dispatch_get_main_queue(), ^{ gImporting = NO; WatchForNewTimeline(gSeqBeforeImport); });
    return r;
}
static void Install(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class C = objc_getClass("FFXMLImporter");
        Method m = C ? class_getInstanceMethod(C, NSSelectorFromString(@"import:")) : NULL;
        if (!m) { XL(@"FFXMLImporter import: not found"); return; }
        gOrigImport = method_setImplementation(m, (IMP)h_import);
        [[NSNotificationCenter defaultCenter] addObserverForName:@"XMLClipsRunNow" object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n){ AddClipsToBrowser(); }];
        // remember which timeline was open before an import starts
        dispatch_async(dispatch_get_main_queue(), ^{ [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) { if (!gImporting && !gWatch) gSeqBeforeImport = ActiveSeq(); }]; });
        XL(@"xml clips ready");
    });
}
__attribute__((visibility("default"))) void SpliceKitPlugin_init(void *ctx) { Install(); }
__attribute__((visibility("default"))) void XMLClips_runNow(void) { dispatch_async(dispatch_get_main_queue(), ^{ AddClipsToBrowser(); }); }
__attribute__((constructor)) static void ctor(void) { dispatch_async(dispatch_get_main_queue(), ^{ Install(); }); }
