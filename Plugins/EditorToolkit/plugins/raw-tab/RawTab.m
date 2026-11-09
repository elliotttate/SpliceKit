// RAW Tab: puts Final Cut Pro's "Edit RAW Properties" controls (from BRAW Toolbox)
// in their own tab inside the inspector. Built for FCP 12.4 + SpliceKit 3.3.9.
// Tab plumbing modelled on Transcript Tab (github.com/bcassin/fcp-transcript-tab, MIT).
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

static NSString *const kTabIdent = @"SKInspectorTabRAWIdentifier";
static void RLog(NSString *fmt, ...) {
    va_list a; va_start(a, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:a]; va_end(a);
    NSString *p = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/SpliceKit/rawtab.log"];
    FILE *f = fopen(p.fileSystemRepresentation, "a");
    if (f) { fprintf(f, "%s %s\n", [NSDate date].description.UTF8String, s.UTF8String); fclose(f); }
}

@interface FFInspectorModule : NSResponder
- (void)setCurrentItems:(id)items;
- (void)setView:(NSView *)view;
- (NSView *)view;
@end

@class SKRawTabModule;
static __weak id gTabModule;
static __weak SKRawTabModule *gModule;
static BOOL gOpeningFromTab;

@interface SKRawContainer : NSView
@property (nonatomic, weak) SKRawTabModule *owner;
@end

@interface SKRawTabModule : FFInspectorModule
@property (nonatomic, strong) SKRawContainer *container;
@property (nonatomic, strong) NSTextField *placeholder;
@property (nonatomic, strong) NSArray *items;
@property (nonatomic) BOOL built;
- (void)sk_refresh;
@end

@implementation SKRawContainer
- (BOOL)isFlipped { return YES; }
- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (self.window) dispatch_async(dispatch_get_main_queue(), ^{ [self.owner sk_refresh]; });
}
@end

static id RHud(void) {
    Class c = objc_getClass("FFVTRAWSettingsHud");
    return c ? ((id(*)(id, SEL))objc_msgSend)(c, NSSelectorFromString(@"shared")) : nil;
}

@implementation SKRawTabModule
- (void)sk_build {
    if (self.built) return;
    self.built = YES;
    gModule = self;
    SKRawContainer *c = [[SKRawContainer alloc] initWithFrame:NSMakeRect(0, 0, 400, 600)];
    c.owner = self;
    c.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    NSTextField *ph = [NSTextField labelWithString:@"Select a RAW clip to edit its RAW settings."];
    ph.textColor = [NSColor secondaryLabelColor];
    ph.alignment = NSTextAlignmentCenter;
    ph.frame = NSMakeRect(10, 40, 380, 20);
    ph.autoresizingMask = NSViewWidthSizable;
    [c addSubview:ph];
    self.placeholder = ph;
    self.container = c;
    [self setView:c];
}
- (instancetype)init { self = [super init]; if (self) [self sk_build]; return self; }
- (BOOL)loadView { [self sk_build]; return YES; }
- (void)loadNib { [self sk_build]; }
- (BOOL)isNibLoaded { return self.built; }
- (NSView *)view { [self sk_build]; return self.container; }
- (BOOL)shouldDisplayModuleWithItems:(id)items { return YES; }
- (void)setCurrentItems:(id)items {
    @try { [super setCurrentItems:items]; } @catch (id e) { RLog(@"super setCurrentItems threw %@", e); }
    [self sk_build];
    self.items = [items isKindOfClass:[NSArray class]] ? [items copy] : nil;
    if (self.container.window) [self sk_refresh];
}
// Move the RAW settings HUD's content into our tab (once), and point it at our items.
- (void)sk_refresh {
    if (!self.container.window) return;
    id hud = RHud();
    if (!hud) { RLog(@"no FFVTRAWSettingsHud"); return; }
    @try {
        NSArray *items = self.items;
        if (!items.count) {
            id tabModule = gTabModule;
            for (NSView *v = self.container.superview; v && !tabModule; v = v.superview)
                if ([v isKindOfClass:[NSTabView class]] && [NSStringFromClass([[(NSTabView *)v delegate] class]) containsString:@"InspectorTab"]) tabModule = [(NSTabView *)v delegate];
            id cur = nil; @try { cur = [tabModule valueForKey:@"currentItems"]; } @catch (id e) {}
            if ([cur isKindOfClass:[NSArray class]]) items = cur;
        }
        if (!items) items = @[];
        RLog(@"refresh with %lu item(s)", (unsigned long)items.count);
        ((void(*)(id, SEL, id))objc_msgSend)(hud, NSSelectorFromString(@"setAssetItems:"), items);
        gOpeningFromTab = YES;
        ((void(*)(id, SEL))objc_msgSend)(hud, NSSelectorFromString(@"openHUD"));   // loads + refreshes; panel is hidden by our hook
        gOpeningFromTab = NO;
        NSPanel *panel = ((id(*)(id, SEL))objc_msgSend)(hud, NSSelectorFromString(@"panel"));
        NSView *content = objc_getAssociatedObject(hud, "sk_rawContent");
        if (!content && panel) {
            content = panel.contentView;
            NSSize natural = content.frame.size;
            panel.contentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 10, 10)];
            objc_setAssociatedObject(hud, "sk_rawContent", content, OBJC_ASSOCIATION_RETAIN);
            RLog(@"moved HUD content into tab (natural size %@)", NSStringFromSize(natural));
        }
        if (content && content.superview != self.container) {
            [content removeFromSuperview];
            content.translatesAutoresizingMaskIntoConstraints = YES;
            content.frame = self.container.bounds;
            content.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
            [self.container addSubview:content];
        }
        self.placeholder.hidden = (content != nil && items.count > 0);
        content.hidden = (items.count == 0);
        [panel orderOut:nil];
    } @catch (id e) {
        gOpeningFromTab = NO;
        RLog(@"refresh threw %@", e);
    }
}
@end

static IMP o_ids, o_image, o_alt, o_button, o_openHUD;

// Final Cut's inspector shows at most 5 tabs. When the identifier list for a selection is longer,
// it silently falls back to just Video + Info - which is how titles lost their Title tab (and clips
// their Color/Audio tabs) once the RAW tab was being added to every selection. So:
//   - the RAW tab is only added for clips whose media really is RAW (BRAW / ProRes RAW)
//   - native tabs are never displaced; if the list is already full, only another plugin's tab
//     (e.g. Transcript) gives up its place for the RAW tab, otherwise the RAW tab is left out.
static const NSUInteger kMaxInspectorTabs = 5;
static BOOL RIsRAWAsset(id a) {
    @try {
        SEL ext = NSSelectorFromString(@"usingRAWMediaExtension"), prr = NSSelectorFromString(@"isProResRAWCodec"), rps = NSSelectorFromString(@"rawProcessorSettings");
        if ([a respondsToSelector:ext] && ((BOOL(*)(id, SEL))objc_msgSend)(a, ext)) return YES;
        if ([a respondsToSelector:prr] && ((BOOL(*)(id, SEL))objc_msgSend)(a, prr)) return YES;
        if ([a respondsToSelector:rps] && ((id(*)(id, SEL))objc_msgSend)(a, rps)) return YES;
    } @catch (id e) {}
    return NO;
}
static BOOL RItemsAreRAW(id items) {
    if (![items respondsToSelector:@selector(countByEnumeratingWithState:objects:count:)]) return NO;
    NSUInteger n = 0;
    SEL as = NSSelectorFromString(@"assetsIncludingAnchored:");
    for (id it in items) {
        n++;
        if (![it respondsToSelector:as]) return NO;
        id assets = ((id(*)(id, SEL, BOOL))objc_msgSend)(it, as, NO);
        BOOL raw = NO;
        for (id a in assets) if (RIsRAWAsset(a)) { raw = YES; break; }
        if (!raw) return NO;                     // every selected clip must be RAW
    }
    return n > 0;
}
static BOOL RIsNative(id k) { return [k isKindOfClass:[NSString class]] ? [k hasPrefix:@"FF"] : YES; }

static BOOL h_ids(id self, SEL _cmd, id items, __autoreleasing id *outIds, __autoreleasing id *outMap) {
    BOOL r = ((BOOL(*)(id,SEL,id,__autoreleasing id*,__autoreleasing id*))o_ids)(self,_cmd,items,outIds,outMap);
    @try {
        gTabModule = self;
        if (!r || !outIds || !outMap || !*outIds || !*outMap) return r;
        BOOL ordered = [*outIds isKindOfClass:[NSOrderedSet class]];
        NSMutableArray *ids = [(ordered ? [(NSOrderedSet *)*outIds array] : (NSArray *)*outIds) mutableCopy];
        NSMapTable *map = *outMap;
        BOOL had = [ids containsObject:kTabIdent];
        [ids removeObject:kTabIdent];
        BOOL want = ![ids containsObject:@"FFInspectorTabLibraryPropertiesIdentifier"]
                 && ![ids containsObject:@"FFInspectorTabProjectPropertiesIdentifier"]
                 && [ids containsObject:@"FFInspectorTabInfoIdentifier"]
                 && RItemsAreRAW(items);
        if (want && ids.count >= kMaxInspectorTabs) {
            for (NSInteger i = (NSInteger)ids.count - 1; i >= 0 && ids.count >= kMaxInspectorTabs; i--)
                if (!RIsNative(ids[i])) { RLog(@"tab limit: %@ makes room for RAW", ids[i]); [ids removeObjectAtIndex:i]; }
            if (ids.count >= kMaxInspectorTabs) { want = NO; RLog(@"tab limit: no room for RAW tab (%lu native tabs)", (unsigned long)ids.count); }
        }
        if (want) {
            id sample = [map objectForKey:ids.firstObject];
            id value;
            if ([sample isKindOfClass:[NSArray class]]) value = @[@"SKRawTabModule"];
            else if ([sample isKindOfClass:[NSString class]]) value = @"SKRawTabModule";
            else value = [SKRawTabModule class];
            [map setObject:value forKey:kTabIdent];
            [ids addObject:kTabIdent];
        } else if (had) [map removeObjectForKey:kTabIdent];
        // safety net for any plugin tab: never let the list grow past what Final Cut can show
        for (NSInteger i = (NSInteger)ids.count - 1; i >= 0 && ids.count > kMaxInspectorTabs; i--)
            if (!RIsNative(ids[i]) && ![ids[i] isEqual:kTabIdent]) { RLog(@"tab limit: dropped %@ so native tabs stay", ids[i]); [ids removeObjectAtIndex:i]; }
        if (want || had || ids.count != ([*outIds count])) *outIds = ordered ? (id)[NSOrderedSet orderedSetWithArray:ids] : (id)[ids copy];
    } @catch (id e) { RLog(@"h_ids threw %@", e); }
    return r;
}
static NSImage *RTabImage(void) {
    static NSImage *img;
    if (img) return img;
    NSImage *sym = [[NSImage imageWithSystemSymbolName:@"camera.aperture" accessibilityDescription:@"RAW"]
        imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:14 weight:NSFontWeightRegular]];
    img = [NSImage imageWithSize:NSMakeSize(18, 18) flipped:NO drawingHandler:^BOOL(NSRect r) {
        NSSize s = sym.size; CGFloat k = MIN(15 / MAX(s.width, 1), 15 / MAX(s.height, 1));
        NSSize f = NSMakeSize(s.width * k, s.height * k);
        [sym drawInRect:NSMakeRect((18 - f.width) / 2, (18 - f.height) / 2, f.width, f.height)];
        return YES;
    }];
    img.template = YES;
    return img;
}
static id h_image(id self, SEL _cmd, id tab) {
    if ([tab isKindOfClass:[NSString class]] && [tab isEqualToString:kTabIdent]) return RTabImage();
    return ((id(*)(id,SEL,id))o_image)(self,_cmd,tab);
}
static id h_alt(id self, SEL _cmd, id tab) {
    if (!([tab isKindOfClass:[NSString class]] && [tab isEqualToString:kTabIdent])) return ((id(*)(id,SEL,id))o_alt)(self,_cmd,tab);
    static NSImage *tinted;
    if (!tinted) {
        NSImage *g = RTabImage(); NSColor *c = [NSColor controlAccentColor];
        tinted = [NSImage imageWithSize:g.size flipped:NO drawingHandler:^BOOL(NSRect r) {
            [g drawInRect:r]; [c set]; NSRectFillUsingOperation(r, NSCompositingOperationSourceAtop); return YES; }];
    }
    return tinted;
}
static id h_button(id self, SEL _cmd, id title, long tag) {
    return ((id(*)(id,SEL,id,long))o_button)(self,_cmd,title ?: @"RAW",tag);
}
// The Info tab's "Edit RAW Properties" button: jump to our tab instead of showing the floating window.
static void h_openHUD(id self, SEL _cmd) {
    ((void(*)(id,SEL))o_openHUD)(self, _cmd);
    @try {
        NSPanel *panel = ((id(*)(id, SEL))objc_msgSend)(self, NSSelectorFromString(@"panel"));
        NSView *content = objc_getAssociatedObject(self, "sk_rawContent");
        if (gOpeningFromTab) { if (content) [panel orderOut:nil]; return; }
        NSInteger tab = -1;
        NSTabView *tv = gTabModule ? [gTabModule valueForKey:@"_tabView"] : nil;
        for (NSUInteger i = 0; i < tv.tabViewItems.count; i++) {
            NSTabViewItem *it = tv.tabViewItems[i];
            if ([it.identifier isEqual:kTabIdent] || (gModule && it.identifier == gModule)) { tab = (NSInteger)i; break; }
        }
        if (tab >= 0) {
            if (content) [panel orderOut:nil];
            ((void(*)(id,SEL,NSUInteger))objc_msgSend)(gTabModule, NSSelectorFromString(@"selectInspectorTab:"), (NSUInteger)tab);
        } else if (content && panel) {
            // no RAW tab for this selection: give the controls back to Final Cut's own floating window
            [content removeFromSuperview];
            content.hidden = NO;
            panel.contentView = content;
            objc_setAssociatedObject(self, "sk_rawContent", nil, OBJC_ASSOCIATION_RETAIN);
            [panel makeKeyAndOrderFront:nil];
            RLog(@"no RAW tab here - showing the native RAW window");
        }
    } @catch (id e) { RLog(@"openHUD hook threw %@", e); }
}
static IMP hook(Class c, NSString *sel, IMP n) {
    Method m = class_getInstanceMethod(c, NSSelectorFromString(sel));
    if (!m) { RLog(@"missing %@", sel); return NULL; }
    return method_setImplementation(m, n);
}
__attribute__((visibility("default"))) void SpliceKitPlugin_init(void *api) { (void)api; }
static void rawtab_install(void) {
    static BOOL done; if (done) return; done = YES;
    Class c = objc_getClass("FFInspectorTabModule");
    Class h = objc_getClass("FFVTRAWSettingsHud");
    if (!c || !h) { RLog(@"missing classes tab=%@ hud=%@", c, h); return; }
    o_ids = hook(c, @"_identifiersAndClassesForItems:outTabIdentifiers:outClassesMap:", (IMP)h_ids);
    o_image = hook(c, @"imageForInspectorTab:", (IMP)h_image);
    o_alt = hook(c, @"altImageForInspectorTab:", (IMP)h_alt);
    o_button = hook(c, @"newTabSelectorButtonWithTitle:tag:", (IMP)h_button);
    o_openHUD = hook(h, @"openHUD", (IMP)h_openHUD);
    RLog(@"RAW Tab loaded (ids=%d image=%d alt=%d button=%d openHUD=%d)", o_ids != NULL, o_image != NULL, o_alt != NULL, o_button != NULL, o_openHUD != NULL);
}
// hook after every other plugin has loaded, so our tab is added on top of theirs (e.g. transcript tab)
__attribute__((constructor)) static void rawtab_init(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ rawtab_install(); });
}
