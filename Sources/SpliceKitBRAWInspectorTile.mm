// SpliceKitBRAWInspectorTile.mm — runtime-built inspector tile.
//
// Builds a subclass of FFInspectorBaseController at dylib load time via
// objc_allocateClassPair so we can interoperate with FCP's FFInspector*
// container hierarchy without linking against Flexo headers at compile time.
// FCP's -[FFInspectorFileInfoTile _addTileOfClass:items:references:owner:]
// instantiates the class, calls -updateWithItems:references:owner:, and adds
// it to the inspector's sub-controller list, which then queries -view.

#import "SpliceKitBRAWInspectorTile.h"
#import "SpliceKitBRAWSettingsHud.h"

#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

static NSString *const kSpliceKitBRAWTileClassName = @"SpliceKitBRAWInspectorFileInfoTile";

// Associated-object keys for tile state. We can't add ivars to a class pair
// *after* registration, so we use objc_setAssociatedObject for instance storage.
static const char kSpliceKitBRAWTileItemsKey = 0;
static const char kSpliceKitBRAWTileRowViewKey = 0;
static const char kSpliceKitBRAWTileButtonKey = 0;

#pragma mark - Helpers (C-function IMPs for the runtime class)

static NSArray *SpliceKitBRAWTile_GetItems(id self) {
    return objc_getAssociatedObject(self, &kSpliceKitBRAWTileItemsKey);
}

static void SpliceKitBRAWTile_SetItems(id self, NSArray *items) {
    // RETAIN, not COPY — match -[FFInspectorFileInfoProResRAWTile updateWithItems:…]
    // which retains the array directly. The items can be NSArray / NSOrderedSet /
    // any retainable container; copy semantics on something other than NSArray
    // would call -mutableCopy or fail and we'd lose the items entirely.
    objc_setAssociatedObject(self,
                             &kSpliceKitBRAWTileItemsKey,
                             items,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

#pragma mark - Tile IMP implementations

static void SpliceKitBRAWTile_updateWithItems(id self, SEL _cmd, id items,
                                              id refs, id owner) {
    (void)refs; (void)owner;
    SpliceKitBRAWTile_SetItems(self, items);
}

static void SpliceKitBRAWTile_modifyButtonPressed(id self, SEL _cmd, id sender) {
    (void)sender;
    SpliceKitBRAWSettingsHud *hud = [SpliceKitBRAWSettingsHud shared];
    NSArray *items = SpliceKitBRAWTile_GetItems(self);
    NSLog(@"[SpliceKitBRAWTile] Modify BRAW pressed, items=%@", items);
    FILE *f = fopen("/tmp/splicekit-braw.log", "a");
    if (f) {
        NSString *line = [NSString stringWithFormat:@"%@ [tile] modify pressed items.count=%lu\n",
            [NSDate date], (unsigned long)items.count];
        fputs(line.UTF8String, f); fclose(f);
    }
    [hud openForItems:items];
}

static id SpliceKitBRAWTile_view(id self, SEL _cmd) {
    NSView *rowView = objc_getAssociatedObject(self, &kSpliceKitBRAWTileRowViewKey);
    if (rowView) {
        return rowView;
    }

    rowView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 320, 72)];
    rowView.translatesAutoresizingMaskIntoConstraints = NO;
    [rowView.heightAnchor constraintEqualToConstant:72.0].active = YES;

    NSButton *button = [NSButton buttonWithTitle:@"Modify BRAW…"
                                          target:self
                                          action:@selector(modifyBRAWSettingsButtonPressed:)];
    button.bezelStyle = NSBezelStyleRounded;
    button.controlSize = NSControlSizeSmall;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [rowView addSubview:button];

    [NSLayoutConstraint activateConstraints:@[
        [button.centerXAnchor constraintEqualToAnchor:rowView.centerXAnchor],
        [button.topAnchor constraintEqualToAnchor:rowView.topAnchor constant:15.0],
    ]];

    // FFInspectorBaseController has a setView: hook that the container uses to
    // thread subviews into the inspector hierarchy. Call it if the superclass
    // responds.
    if ([self respondsToSelector:@selector(setView:)]) {
        ((void (*)(id, SEL, id))objc_msgSend)(self, @selector(setView:), rowView);
    }

    objc_setAssociatedObject(self, &kSpliceKitBRAWTileRowViewKey, rowView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, &kSpliceKitBRAWTileButtonKey, button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return rowView;
}

// Some FFInspector tile code paths call -dealloc; we don't need custom teardown
// because associated objects + ARC handle everything. But FCP's inspector
// sometimes probes -respondsToSelector: on tiles, so keep methods explicit.

#pragma mark - Public registration

@implementation SpliceKitBRAWInspectorTile

+ (NSString *)runtimeClassName {
    return kSpliceKitBRAWTileClassName;
}

+ (Class)registerTileClass {
    static Class runtimeClass;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class existing = objc_getClass([kSpliceKitBRAWTileClassName UTF8String]);
        if (existing) {
            runtimeClass = existing;
            return;
        }
        Class superclass = objc_getClass("FFInspectorBaseController");
        if (!superclass) {
            // FFInspectorBaseController lives in Flexo.framework. If it's not
            // present (e.g. pre-FCP bootstrap), fail gracefully — the tile just
            // can't be injected until FCP's inspector is loaded. Callers should
            // retry registration later.
            runtimeClass = nil;
            return;
        }
        Class cls = objc_allocateClassPair(superclass,
                                           [kSpliceKitBRAWTileClassName UTF8String],
                                           0);
        if (!cls) {
            runtimeClass = nil;
            return;
        }

        // -updateWithItems:references:owner:
        class_addMethod(cls,
                        NSSelectorFromString(@"updateWithItems:references:owner:"),
                        (IMP)SpliceKitBRAWTile_updateWithItems,
                        "v@:@@@");

        // -modifyBRAWSettingsButtonPressed:
        class_addMethod(cls,
                        @selector(modifyBRAWSettingsButtonPressed:),
                        (IMP)SpliceKitBRAWTile_modifyButtonPressed,
                        "v@:@");

        // -view
        class_addMethod(cls,
                        @selector(view),
                        (IMP)SpliceKitBRAWTile_view,
                        "@@:");

        objc_registerClassPair(cls);
        runtimeClass = cls;
    });
    return runtimeClass;
}

@end
