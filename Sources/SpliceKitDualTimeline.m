//
//  SpliceKitDualTimeline.m
//  Floating secondary timeline window support for Final Cut Pro.
//
//  The MVP uses FCP's existing PEEditorContainerModule window creation path
//  and keeps command routing focused on whichever editor container currently
//  owns the key window / first responder chain.
//

#import "SpliceKit.h"
#import <AppKit/AppKit.h>
#import <objc/message.h>

static NSString * const kSpliceKitDualEditorContainerID = @"SKDualEditorContainer";
static NSString * const kSpliceKitDualEditorWindowModuleID = @"SKDualEditorWindowModule";
static const CGFloat kSpliceKitDualTimelineSecondaryBrowserMinimumCanvasWidth = 120.0;
static const CGFloat kSpliceKitDualTimelineSecondaryBrowserPaneMinimumWidth = 220.0;
static const CGFloat kSpliceKitDualTimelineSecondaryBrowserPaneMaximumWidth = 2400.0;

static IMP sOriginalActiveEditorContainer = NULL;
static IMP sOriginalEditorContainerFirstResponderChanged = NULL;
static IMP sOriginalEditorContainerWindowDidBecomeKey = NULL;
static IMP sOriginalEditorContainerViewDidLoad = NULL;
static IMP sOriginalMediaBrowserViewMinSize = NULL;
static IMP sOriginalContentBrowserConstrainWidth = NULL;
static IMP sOriginalContentBrowserViewDidLoad = NULL;
static IMP sOriginalWindowModuleShouldSaveToLayout = NULL;
static IMP sOriginalLayoutManagerExistingModuleFromLayout = NULL;

// Track whether the dual timeline swizzles were fully installed.
// Code that walks the focus chain (e.g. getActiveTimelineModule) must
// check this before calling into the dual timeline functions.
static BOOL sDualTimelineInstalled = NO;

static __weak id sFocusedEditorContainer = nil;
static __weak id sSecondaryContentBrowserModule = nil;
static __weak id sSecondaryRootWindowModule = nil;

id SpliceKit_dualTimelineFocusedEditorContainer(void);
id SpliceKit_dualTimelinePrimaryEditorContainer(void);
id SpliceKit_dualTimelineSecondaryEditorContainer(BOOL createIfNeeded);
static BOOL SpliceKit_dualTimelineWindowModuleIsSecondary(id windowModule);

static id SpliceKit_dualTimelineAppController(void) {
    id app = ((id (*)(id, SEL))objc_msgSend)(objc_getClass("NSApplication"), @selector(sharedApplication));
    return app ? ((id (*)(id, SEL))objc_msgSend)(app, @selector(delegate)) : nil;
}

static NSString *SpliceKit_dualTimelineIdentifierForContainer(id container) {
    if (!container) return nil;

    SEL identifierSel = NSSelectorFromString(@"identifier");
    if ([container respondsToSelector:identifierSel]) {
        id identifier = ((id (*)(id, SEL))objc_msgSend)(container, identifierSel);
        if ([identifier isKindOfClass:[NSString class]]) {
            return identifier;
        }
    }

    @try {
        id identifier = [container valueForKey:@"identifier"];
        if ([identifier isKindOfClass:[NSString class]]) {
            return identifier;
        }
    } @catch (__unused NSException *e) {
    }

    return nil;
}

static id SpliceKit_dualTimelineEditorModuleForContainer(id container) {
    if (!container) return nil;
    SEL editorModuleSel = NSSelectorFromString(@"editorModule");
    return [container respondsToSelector:editorModuleSel]
        ? ((id (*)(id, SEL))objc_msgSend)(container, editorModuleSel)
        : nil;
}

static id SpliceKit_dualTimelineTimelineModuleForContainer(id container) {
    if (!container) return nil;
    SEL timelineModuleSel = NSSelectorFromString(@"timelineModule");
    if ([container respondsToSelector:timelineModuleSel]) {
        return ((id (*)(id, SEL))objc_msgSend)(container, timelineModuleSel);
    }
    return SpliceKit_dualTimelineEditorModuleForContainer(container);
}

static NSView *SpliceKit_dualTimelineOuterBrowserHostViewForContainer(id container) {
    if (!container) return nil;

    id browserView = nil;
    @try {
        browserView = [container valueForKey:@"_browserView"];
    } @catch (__unused NSException *e) {
    }

    return [browserView isKindOfClass:[NSView class]] ? browserView : nil;
}

static id SpliceKit_dualTimelineEditorSplitViewForContainer(id container) {
    if (!container) return nil;

    id splitView = nil;
    @try {
        splitView = [container valueForKey:@"_timelineAndIndexSplitView"];
    } @catch (__unused NSException *e) {
    }

    return splitView;
}

static BOOL SpliceKit_dualTimelineModuleBelongsToSecondaryWindow(id module) {
    if (!module) return NO;

    id view = [module respondsToSelector:@selector(view)]
        ? ((id (*)(id, SEL))objc_msgSend)(module, @selector(view))
        : nil;
    id window = view && [view respondsToSelector:@selector(window)]
        ? ((id (*)(id, SEL))objc_msgSend)(view, @selector(window))
        : nil;
    id windowController = window && [window respondsToSelector:@selector(windowController)]
        ? ((id (*)(id, SEL))objc_msgSend)(window, @selector(windowController))
        : nil;
    id rootModule = [windowController respondsToSelector:NSSelectorFromString(@"rootModule")]
        ? ((id (*)(id, SEL))objc_msgSend)(windowController, NSSelectorFromString(@"rootModule"))
        : nil;
    return SpliceKit_dualTimelineWindowModuleIsSecondary(rootModule);
}

static id SpliceKit_dualTimelineWindowForContainer(id container) {
    if (!container) return nil;
    SEL windowSel = NSSelectorFromString(@"window");
    if ([container respondsToSelector:windowSel]) {
        return ((id (*)(id, SEL))objc_msgSend)(container, windowSel);
    }

    id view = ((id (*)(id, SEL))objc_msgSend)(container, @selector(view));
    return view ? ((id (*)(id, SEL))objc_msgSend)(view, @selector(window)) : nil;
}

static id SpliceKit_dualTimelineWindowControllerForContainer(id container) {
    id window = SpliceKit_dualTimelineWindowForContainer(container);
    return window && [window respondsToSelector:@selector(windowController)]
        ? ((id (*)(id, SEL))objc_msgSend)(window, @selector(windowController))
        : nil;
}

static id SpliceKit_dualTimelineRootWindowModuleForContainer(id container) {
    id windowController = SpliceKit_dualTimelineWindowControllerForContainer(container);
    SEL rootModuleSel = NSSelectorFromString(@"rootModule");
    return [windowController respondsToSelector:rootModuleSel]
        ? ((id (*)(id, SEL))objc_msgSend)(windowController, rootModuleSel)
        : nil;
}

static id SpliceKit_dualTimelineOriginalActiveEditorContainer(id appController) {
    if (appController && sOriginalActiveEditorContainer) {
        return ((id (*)(id, SEL))sOriginalActiveEditorContainer)(appController, @selector(activeEditorContainer));
    }

    if (appController && [appController respondsToSelector:NSSelectorFromString(@"mainEditorContainer")]) {
        return ((id (*)(id, SEL))objc_msgSend)(appController, NSSelectorFromString(@"mainEditorContainer"));
    }

    return nil;
}

static BOOL SpliceKit_dualTimelineContainerOwnsActiveModule(id container) {
    if (!container) return NO;

    id window = SpliceKit_dualTimelineWindowForContainer(container);
    if (!window || ![window respondsToSelector:NSSelectorFromString(@"activeModule")]) {
        return YES;
    }

    id activeModule = ((id (*)(id, SEL))objc_msgSend)(window, NSSelectorFromString(@"activeModule"));
    SEL ancestorSel = NSSelectorFromString(@"isAncestorOfModule:");
    if ([container respondsToSelector:ancestorSel]) {
        return ((BOOL (*)(id, SEL, id))objc_msgSend)(container, ancestorSel, activeModule);
    }

    return YES;
}

static BOOL SpliceKit_dualTimelineIsUsableContainer(id container) {
    if (!container) return NO;
    if (!SpliceKit_dualTimelineEditorModuleForContainer(container)) return NO;

    id window = SpliceKit_dualTimelineWindowForContainer(container);
    if (window && [window respondsToSelector:@selector(isVisible)] &&
        !((BOOL (*)(id, SEL))objc_msgSend)(window, @selector(isVisible))) {
        return NO;
    }

    return YES;
}

static NSDictionary *SpliceKit_dualTimelineContainerInfo(id container, NSString *paneName) {
    if (!container) {
        return @{@"pane": paneName ?: @"",
                 @"present": @NO};
    }

    id window = SpliceKit_dualTimelineWindowForContainer(container);
    id editorModule = SpliceKit_dualTimelineEditorModuleForContainer(container);

    id sequence = nil;
    id rootItem = nil;
    if (editorModule && [editorModule respondsToSelector:NSSelectorFromString(@"sequence")]) {
        sequence = ((id (*)(id, SEL))objc_msgSend)(editorModule, NSSelectorFromString(@"sequence"));
    }
    if (editorModule && [editorModule respondsToSelector:NSSelectorFromString(@"rootItem")]) {
        rootItem = ((id (*)(id, SEL))objc_msgSend)(editorModule, NSSelectorFromString(@"rootItem"));
    }

    NSString *sequenceName = nil;
    if (sequence && [sequence respondsToSelector:@selector(displayName)]) {
        sequenceName = ((id (*)(id, SEL))objc_msgSend)(sequence, @selector(displayName));
    }

    NSString *rootName = nil;
    if (rootItem && [rootItem respondsToSelector:@selector(displayName)]) {
        rootName = ((id (*)(id, SEL))objc_msgSend)(rootItem, @selector(displayName));
    }

    NSString *windowTitle = nil;
    if (window && [window respondsToSelector:@selector(title)]) {
        windowTitle = ((id (*)(id, SEL))objc_msgSend)(window, @selector(title));
    }

    BOOL keyWindow = window && [window respondsToSelector:@selector(isKeyWindow)]
        ? ((BOOL (*)(id, SEL))objc_msgSend)(window, @selector(isKeyWindow))
        : NO;
    BOOL visible = window && [window respondsToSelector:@selector(isVisible)]
        ? ((BOOL (*)(id, SEL))objc_msgSend)(window, @selector(isVisible))
        : NO;

    return @{
        @"pane": paneName ?: @"",
        @"present": @YES,
        @"identifier": SpliceKit_dualTimelineIdentifierForContainer(container) ?: @"",
        @"windowTitle": windowTitle ?: @"",
        @"visible": @(visible),
        @"keyWindow": @(keyWindow),
        @"sequenceName": sequenceName ?: @"",
        @"rootName": rootName ?: @"",
        @"editorClass": editorModule ? NSStringFromClass([editorModule class]) : @"",
    };
}

static CGRect SpliceKit_dualTimelineDefaultFrame(void) {
    CGRect frame = CGRectMake(140.0, 120.0, 1400.0, 900.0);

    id primary = SpliceKit_dualTimelinePrimaryEditorContainer();
    id window = SpliceKit_dualTimelineWindowForContainer(primary);
    if (window) {
        CGRect mainFrame = [(NSWindow *)window frame];
        frame = CGRectOffset(mainFrame, 36.0, -36.0);
    } else if ([NSScreen mainScreen]) {
        frame = [NSScreen mainScreen].visibleFrame;
        frame.origin.x += 60.0;
        frame.origin.y += 40.0;
        frame.size.width = MAX(900.0, frame.size.width * 0.78);
        frame.size.height = MAX(600.0, frame.size.height * 0.78);
    }

    return frame;
}

static id SpliceKit_dualTimelineBrowserSplitView(id browserModule) {
    if (!browserModule) return nil;
    SEL splitViewSel = NSSelectorFromString(@"splitView");
    return [browserModule respondsToSelector:splitViewSel]
        ? ((id (*)(id, SEL))objc_msgSend)(browserModule, splitViewSel)
        : nil;
}

static BOOL SpliceKit_dualTimelineBrowserModuleBelongsToSecondaryWindow(id browserModule) {
    if (!browserModule) return NO;
    if (browserModule == sSecondaryContentBrowserModule) return YES;

    id view = [browserModule respondsToSelector:@selector(view)]
        ? ((id (*)(id, SEL))objc_msgSend)(browserModule, @selector(view))
        : nil;
    id window = view && [view respondsToSelector:@selector(window)]
        ? ((id (*)(id, SEL))objc_msgSend)(view, @selector(window))
        : nil;
    id windowController = window && [window respondsToSelector:@selector(windowController)]
        ? ((id (*)(id, SEL))objc_msgSend)(window, @selector(windowController))
        : nil;
    id rootModule = [windowController respondsToSelector:NSSelectorFromString(@"rootModule")]
        ? ((id (*)(id, SEL))objc_msgSend)(windowController, NSSelectorFromString(@"rootModule"))
        : nil;

    if (SpliceKit_dualTimelineWindowModuleIsSecondary(rootModule)) {
        sSecondaryContentBrowserModule = browserModule;
        return YES;
    }

    return NO;
}

static id SpliceKit_dualTimelineWrappedContentBrowserModuleForContainer(id container) {
    SEL browserSel = NSSelectorFromString(@"browserModule");
    id browserModule = [container respondsToSelector:browserSel]
        ? ((id (*)(id, SEL))objc_msgSend)(container, browserSel)
        : nil;
    if (!browserModule) return nil;

    if ([browserModule isKindOfClass:objc_getClass("FFContentBrowserModule")]) {
        return browserModule;
    }

    id wrapped = nil;
    @try {
        wrapped = [browserModule valueForKey:@"_contentBrowserModule"];
    } @catch (__unused NSException *e) {
    }
    return wrapped ?: browserModule;
}

static void SpliceKit_dualTimelineRelaxBrowserWidthConstraints(id browserModule) {
    id splitView = SpliceKit_dualTimelineBrowserSplitView(browserModule);
    if (!splitView || ![splitView respondsToSelector:@selector(subviews)]) return;

    NSArray *subviews = ((id (*)(id, SEL))objc_msgSend)(splitView, @selector(subviews));
    if (![subviews isKindOfClass:[NSArray class]] || subviews.count < 2) return;

    NSView *contentView = subviews[1];
    if (![contentView isKindOfClass:[NSView class]]) return;

    for (NSLayoutConstraint *constraint in contentView.constraints) {
        BOOL widthMinimum = constraint.firstItem == contentView &&
            constraint.firstAttribute == NSLayoutAttributeWidth &&
            constraint.relation == NSLayoutRelationGreaterThanOrEqual &&
            constraint.secondItem == nil;
        if (widthMinimum && constraint.constant > kSpliceKitDualTimelineSecondaryBrowserMinimumCanvasWidth) {
            constraint.constant = kSpliceKitDualTimelineSecondaryBrowserMinimumCanvasWidth;
        }
    }

    if ([splitView respondsToSelector:@selector(layoutSubtreeIfNeeded)]) {
        ((void (*)(id, SEL))objc_msgSend)(splitView, @selector(layoutSubtreeIfNeeded));
    }
    [contentView layoutSubtreeIfNeeded];
}

static void SpliceKit_dualTimelineRelaxBrowserWidthConstraintsForContainer(id container) {
    if (!container) return;

    id browserModule = SpliceKit_dualTimelineWrappedContentBrowserModuleForContainer(container);
    if (!browserModule) return;

    if ([SpliceKit_dualTimelineIdentifierForContainer(container) isEqualToString:kSpliceKitDualEditorContainerID]) {
        sSecondaryContentBrowserModule = browserModule;
    }
    SpliceKit_dualTimelineRelaxBrowserWidthConstraints(browserModule);
}

static void SpliceKit_dualTimelineRelaxOuterBrowserWidthConstraintsForContainer(id container) {
    if (!container) return;
    NSString *containerIdentifier = SpliceKit_dualTimelineIdentifierForContainer(container) ?: @"";
    if (![containerIdentifier isEqualToString:kSpliceKitDualEditorContainerID]) {
        return;
    }

    NSView *browserView = SpliceKit_dualTimelineOuterBrowserHostViewForContainer(container);
    if (!browserView) return;

    for (NSLayoutConstraint *constraint in browserView.constraints) {
        BOOL widthConstraint = constraint.firstItem == browserView &&
            constraint.firstAttribute == NSLayoutAttributeWidth &&
            constraint.secondItem == nil;
        if (!widthConstraint) continue;

        if (constraint.relation == NSLayoutRelationGreaterThanOrEqual &&
            constraint.constant > kSpliceKitDualTimelineSecondaryBrowserPaneMinimumWidth) {
            constraint.constant = kSpliceKitDualTimelineSecondaryBrowserPaneMinimumWidth;
        } else if (constraint.relation == NSLayoutRelationLessThanOrEqual &&
                   constraint.constant < kSpliceKitDualTimelineSecondaryBrowserPaneMaximumWidth) {
            constraint.constant = kSpliceKitDualTimelineSecondaryBrowserPaneMaximumWidth;
        }
    }

    id splitView = SpliceKit_dualTimelineEditorSplitViewForContainer(container);
    if ([splitView respondsToSelector:@selector(layoutSubtreeIfNeeded)]) {
        ((void (*)(id, SEL))objc_msgSend)(splitView, @selector(layoutSubtreeIfNeeded));
    }
    [browserView layoutSubtreeIfNeeded];
}

static void SpliceKit_dualTimelineTrackSecondaryWindowModule(id container) {
    NSString *containerIdentifier = SpliceKit_dualTimelineIdentifierForContainer(container) ?: @"";
    if (![containerIdentifier isEqualToString:kSpliceKitDualEditorContainerID]) {
        return;
    }

    id rootModule = SpliceKit_dualTimelineRootWindowModuleForContainer(container);
    if (!rootModule) return;

    sSecondaryRootWindowModule = rootModule;

    SEL identifierSel = NSSelectorFromString(@"identifier");
    id identifier = [rootModule respondsToSelector:identifierSel]
        ? ((id (*)(id, SEL))objc_msgSend)(rootModule, identifierSel)
        : nil;
    SEL setIdentifierSel = NSSelectorFromString(@"setIdentifier:");
    if ((!identifier || ([identifier isKindOfClass:[NSString class]] && [identifier length] == 0)) &&
        [rootModule respondsToSelector:setIdentifierSel]) {
        ((void (*)(id, SEL, id))objc_msgSend)(rootModule, setIdentifierSel, kSpliceKitDualEditorWindowModuleID);
    }
}

static BOOL SpliceKit_dualTimelineWindowModuleIsSecondary(id windowModule) {
    if (!windowModule) return NO;
    if (windowModule == sSecondaryRootWindowModule) return YES;

    SEL identifierSel = NSSelectorFromString(@"identifier");
    id identifier = [windowModule respondsToSelector:identifierSel]
        ? ((id (*)(id, SEL))objc_msgSend)(windowModule, identifierSel)
        : nil;
    if ([identifier isKindOfClass:[NSString class]] &&
        [identifier isEqualToString:kSpliceKitDualEditorWindowModuleID]) {
        return YES;
    }

    SEL submoduleSel = NSSelectorFromString(@"submoduleWithIdentifier:");
    if ([windowModule respondsToSelector:submoduleSel]) {
        id submodule = ((id (*)(id, SEL, id))objc_msgSend)(windowModule, submoduleSel, kSpliceKitDualEditorContainerID);
        if (submodule) {
            sSecondaryRootWindowModule = windowModule;
            return YES;
        }
    }

    return NO;
}

static id SpliceKit_dualTimelineLookupInstalledContainer(NSString *identifier) {
    if (identifier.length == 0) return nil;

    Class lkViewModuleClass = objc_getClass("LKViewModule");
    SEL installedSel = NSSelectorFromString(@"installedModuleWithIdentifier:");
    if (!lkViewModuleClass || ![lkViewModuleClass respondsToSelector:installedSel]) {
        return nil;
    }

    return ((id (*)(id, SEL, id))objc_msgSend)((id)lkViewModuleClass, installedSel, identifier);
}

static void SpliceKit_dualTimelineSetFocusedContainer(id container, BOOL rebindEditorState) {
    if (!container) return;
    sFocusedEditorContainer = container;

    if (!rebindEditorState) return;

    id editorModule = SpliceKit_dualTimelineEditorModuleForContainer(container);
    SEL makeActiveSel = NSSelectorFromString(@"_makeEditorActive:");
    if (editorModule && [container respondsToSelector:makeActiveSel]) {
        ((void (*)(id, SEL, id))objc_msgSend)(container, makeActiveSel, editorModule);
    }

    if (editorModule) {
        Class numericEntryManagerClass = objc_getClass("PENumericEntryManager");
        SEL sharedSel = NSSelectorFromString(@"sharedNumericEntryManager");
        SEL setActiveSel = NSSelectorFromString(@"setActiveModule:");
        if (numericEntryManagerClass && [numericEntryManagerClass respondsToSelector:sharedSel]) {
            id manager = ((id (*)(id, SEL))objc_msgSend)((id)numericEntryManagerClass, sharedSel);
            if (manager && [manager respondsToSelector:setActiveSel]) {
                ((void (*)(id, SEL, id))objc_msgSend)(manager, setActiveSel, editorModule);
            }
        }
    }

    SEL footerSel = NSSelectorFromString(@"focusChangedUpdateTimelineFooterString");
    if ([container respondsToSelector:footerSel]) {
        ((void (*)(id, SEL))objc_msgSend)(container, footerSel);
    }
}

static id SpliceKit_dualTimelineSourceContainerForParams(NSDictionary *params) {
    NSString *source = [params[@"source"] isKindOfClass:[NSString class]] ? params[@"source"] : @"primary";

    if ([source isEqualToString:@"focused"]) {
        id focused = SpliceKit_dualTimelineFocusedEditorContainer();
        return focused ?: SpliceKit_dualTimelinePrimaryEditorContainer();
    }
    if ([source isEqualToString:@"secondary"]) {
        return SpliceKit_dualTimelineSecondaryEditorContainer(NO);
    }

    return SpliceKit_dualTimelinePrimaryEditorContainer();
}

static id SpliceKit_dualTimelineSequenceForEditor(id editorModule) {
    if (!editorModule) return nil;

    SEL sequenceSel = NSSelectorFromString(@"sequence");
    if ([editorModule respondsToSelector:sequenceSel]) {
        return ((id (*)(id, SEL))objc_msgSend)(editorModule, sequenceSel);
    }

    SEL providerSel = NSSelectorFromString(@"provider");
    SEL objectSel = NSSelectorFromString(@"object");
    if ([editorModule respondsToSelector:providerSel]) {
        id provider = ((id (*)(id, SEL))objc_msgSend)(editorModule, providerSel);
        if (provider && [provider respondsToSelector:objectSel]) {
            return ((id (*)(id, SEL))objc_msgSend)(provider, objectSel);
        }
    }

    return nil;
}

static id SpliceKit_dualTimelineRootItemForEditor(id editorModule) {
    if (!editorModule) return nil;
    SEL rootItemSel = NSSelectorFromString(@"rootItem");
    if ([editorModule respondsToSelector:rootItemSel]) {
        return ((id (*)(id, SEL))objc_msgSend)(editorModule, rootItemSel);
    }
    return nil;
}

static id SpliceKit_dualTimelinePrimaryObjectForSequence(id sequence) {
    if (!sequence) return nil;
    SEL primaryObjectSel = NSSelectorFromString(@"primaryObject");
    if ([sequence respondsToSelector:primaryObjectSel]) {
        return ((id (*)(id, SEL))objc_msgSend)(sequence, primaryObjectSel);
    }
    return nil;
}

static NSArray *SpliceKit_dualTimelineSelectedItemsForTimeline(id timelineModule) {
    if (!timelineModule) return nil;

    SEL selectedItemsWithFallbackSel = NSSelectorFromString(@"selectedItems:includeItemBeforePlayheadIfLast:");
    if ([timelineModule respondsToSelector:selectedItemsWithFallbackSel]) {
        id selected = ((id (*)(id, SEL, BOOL, BOOL))objc_msgSend)(timelineModule, selectedItemsWithFallbackSel, NO, NO);
        return [selected isKindOfClass:[NSArray class]] ? selected : nil;
    }

    SEL selectedItemsSel = NSSelectorFromString(@"selectedItems");
    if ([timelineModule respondsToSelector:selectedItemsSel]) {
        id selected = ((id (*)(id, SEL))objc_msgSend)(timelineModule, selectedItemsSel);
        return [selected isKindOfClass:[NSArray class]] ? selected : nil;
    }

    return nil;
}

static void SpliceKit_dualTimelineLoadSequenceIntoContainer(id container, id sequence) {
    if (!container || !sequence) return;
    SEL loadSel = NSSelectorFromString(@"loadEditorForSequence:");
    if ([container respondsToSelector:loadSel]) {
        ((void (*)(id, SEL, id))objc_msgSend)(container, loadSel, sequence);
    }
}

static void SpliceKit_dualTimelineFocusWindowForContainer(id container) {
    id window = SpliceKit_dualTimelineWindowForContainer(container);
    if (window && [window respondsToSelector:@selector(makeKeyAndOrderFront:)]) {
        ((void (*)(id, SEL, id))objc_msgSend)(window, @selector(makeKeyAndOrderFront:), nil);
    }
    SpliceKit_dualTimelineSetFocusedContainer(container, YES);
}

static BOOL SpliceKit_dualTimelineContainerSubmoduleVisible(id container, id submodule) {
    if (!container || !submodule) return NO;

    SEL isVisibleSel = NSSelectorFromString(@"isSubmoduleVisible:");
    if ([container respondsToSelector:isVisibleSel]) {
        return ((BOOL (*)(id, SEL, id))objc_msgSend)(container, isVisibleSel, submodule);
    }

    SEL isHiddenSel = NSSelectorFromString(@"isSubmoduleHidden:");
    if ([container respondsToSelector:isHiddenSel]) {
        return !((BOOL (*)(id, SEL, id))objc_msgSend)(container, isHiddenSel, submodule);
    }

    if ([submodule respondsToSelector:@selector(isVisible)]) {
        return ((BOOL (*)(id, SEL))objc_msgSend)(submodule, @selector(isVisible));
    }
    if ([submodule respondsToSelector:@selector(isHidden)]) {
        return !((BOOL (*)(id, SEL))objc_msgSend)(submodule, @selector(isHidden));
    }

    return NO;
}

static NSDictionary *SpliceKit_dualTimelinePanelInfo(id container, NSString *panel, BOOL visible, NSDictionary *extra) {
    NSMutableDictionary *result = [@{
        @"status": @"ok",
        @"action": @"togglePanel",
        @"pane": SpliceKit_dualTimelineIdentifierForContainer(container) ?: @"",
        @"panel": panel ?: @"",
        @"visible": @(visible),
    } mutableCopy];
    [result addEntriesFromDictionary:extra ?: @{}];
    return result;
}

static NSDictionary *SpliceKit_dualTimelineToggleSubmodule(id container, id submodule, NSString *panel) {
    if (!container || !submodule) {
        return @{@"error": [NSString stringWithFormat:@"Secondary window does not expose %@", panel ?: @"that panel"]};
    }

    BOOL visible = SpliceKit_dualTimelineContainerSubmoduleVisible(container, submodule);
    SEL actionSel = visible ? NSSelectorFromString(@"hideSubmodule:") : NSSelectorFromString(@"unhideSubmodule:");
    if (![container respondsToSelector:actionSel]) {
        return @{@"error": [NSString stringWithFormat:@"Container cannot toggle %@", panel ?: @"that panel"]};
    }

    ((void (*)(id, SEL, id))objc_msgSend)(container, actionSel, submodule);
    SpliceKit_dualTimelineRelaxOuterBrowserWidthConstraintsForContainer(container);
    BOOL newVisible = SpliceKit_dualTimelineContainerSubmoduleVisible(container, submodule);
    return SpliceKit_dualTimelinePanelInfo(container, panel, newVisible, nil);
}

static NSDictionary *SpliceKit_dualTimelineToggleMediaBrowserMode(id container,
                                                                  NSInteger tag,
                                                                  NSString *panel)
{
    if (!container) {
        return @{@"error": @"No secondary editor container is available"};
    }

    SEL browserSel = NSSelectorFromString(@"browserModule");
    id browserModule = [container respondsToSelector:browserSel]
        ? ((id (*)(id, SEL))objc_msgSend)(container, browserSel)
        : nil;
    if (!browserModule) {
        return @{@"error": @"Secondary window does not expose a media browser"};
    }

    BOOL visible = SpliceKit_dualTimelineContainerSubmoduleVisible(container, browserModule);
    NSInteger currentMode = [browserModule respondsToSelector:NSSelectorFromString(@"currentEffectsMode")]
        ? ((NSInteger (*)(id, SEL))objc_msgSend)(browserModule, NSSelectorFromString(@"currentEffectsMode"))
        : -1;

    if (visible && currentMode == tag) {
        SEL hideSel = NSSelectorFromString(@"hideSubmodule:");
        if ([container respondsToSelector:hideSel]) {
            ((void (*)(id, SEL, id))objc_msgSend)(container, hideSel, browserModule);
        }
        SEL stateSel = NSSelectorFromString(@"setMediaBrowserButtonState:");
        if ([container respondsToSelector:stateSel]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(container, stateSel, NO);
        }
        return SpliceKit_dualTimelinePanelInfo(container, panel, NO, @{@"modeTag": @(tag)});
    }

    SEL unhideSel = NSSelectorFromString(@"unhideSubmodule:");
    if ([container respondsToSelector:unhideSel] && !visible) {
        ((void (*)(id, SEL, id))objc_msgSend)(container, unhideSel, browserModule);
    }

    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    item.tag = tag;
    SEL revealSel = NSSelectorFromString(@"revealMediaBrowserModeFromMenuTag:");
    if (![container respondsToSelector:revealSel]) {
        return @{@"error": @"Secondary container cannot reveal media browser modes"};
    }
    ((void (*)(id, SEL, id))objc_msgSend)(container, revealSel, item);

    SEL stateSel = NSSelectorFromString(@"setMediaBrowserButtonState:");
    if ([container respondsToSelector:stateSel]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(container, stateSel, YES);
    }

    SpliceKit_dualTimelineRelaxBrowserWidthConstraints(browserModule);
    SpliceKit_dualTimelineRelaxOuterBrowserWidthConstraintsForContainer(container);

    BOOL newVisible = SpliceKit_dualTimelineContainerSubmoduleVisible(container, browserModule);
    NSInteger newMode = [browserModule respondsToSelector:NSSelectorFromString(@"currentEffectsMode")]
        ? ((NSInteger (*)(id, SEL))objc_msgSend)(browserModule, NSSelectorFromString(@"currentEffectsMode"))
        : tag;
    return SpliceKit_dualTimelinePanelInfo(container, panel, newVisible, @{@"modeTag": @(newMode)});
}

static double SpliceKit_dualTimelineSwizzledContentBrowserConstrainWidth(id self, SEL _cmd, double proposedWidth) {
    if (SpliceKit_dualTimelineBrowserModuleBelongsToSecondaryWindow(self)) {
        sSecondaryContentBrowserModule = self;
    }

    SpliceKit_dualTimelineRelaxBrowserWidthConstraints(self);

    id splitView = SpliceKit_dualTimelineBrowserSplitView(self);
    if (splitView && [splitView respondsToSelector:@selector(bounds)]) {
        NSRect bounds = ((NSRect (*)(id, SEL))objc_msgSend)(splitView, @selector(bounds));
        double maxWidth = NSWidth(bounds) - kSpliceKitDualTimelineSecondaryBrowserMinimumCanvasWidth;
        return fmin(proposedWidth, fmax(80.0, maxWidth));
    }

    if (sOriginalContentBrowserConstrainWidth) {
        return ((double (*)(id, SEL, double))sOriginalContentBrowserConstrainWidth)(self, _cmd, proposedWidth);
    }
    return proposedWidth;
}

static void SpliceKit_dualTimelineSwizzledContentBrowserViewDidLoad(id self, SEL _cmd) {
    if (sOriginalContentBrowserViewDidLoad) {
        ((void (*)(id, SEL))sOriginalContentBrowserViewDidLoad)(self, _cmd);
    }
    SpliceKit_dualTimelineRelaxBrowserWidthConstraints(self);
}

static BOOL SpliceKit_dualTimelineSwizzledWindowModuleShouldSaveToLayout(id self, SEL _cmd) {
    if (SpliceKit_dualTimelineWindowModuleIsSecondary(self)) {
        return NO;
    }

    if (sOriginalWindowModuleShouldSaveToLayout) {
        return ((BOOL (*)(id, SEL))sOriginalWindowModuleShouldSaveToLayout)(self, _cmd);
    }
    return YES;
}

static id SpliceKit_dualTimelineSwizzledExistingModuleFromLayoutDictionary(id self, SEL _cmd, id layoutDictionary) {
    id identifier = nil;
    if ([layoutDictionary respondsToSelector:@selector(objectForKey:)]) {
        identifier = ((id (*)(id, SEL, id))objc_msgSend)(layoutDictionary, @selector(objectForKey:), @"identifier");
    }

    if (!identifier || identifier == [NSNull null] ||
        ([identifier isKindOfClass:[NSString class]] && [identifier length] == 0)) {
        id className = [layoutDictionary respondsToSelector:@selector(objectForKey:)]
            ? ((id (*)(id, SEL, id))objc_msgSend)(layoutDictionary, @selector(objectForKey:), @"className")
            : nil;
        SpliceKit_log(@"[DualTimeline] Skipping existing-module restore lookup for layout without identifier (class=%@)",
                      className ?: @"");
        return nil;
    }

    if (sOriginalLayoutManagerExistingModuleFromLayout) {
        return ((id (*)(id, SEL, id))sOriginalLayoutManagerExistingModuleFromLayout)(self, _cmd, layoutDictionary);
    }
    return nil;
}

static id SpliceKit_dualTimelineSwizzledActiveEditorContainer(id self, SEL _cmd) {
    id focused = sFocusedEditorContainer;
    if (SpliceKit_dualTimelineIsUsableContainer(focused)) {
        id focusedWindow = SpliceKit_dualTimelineWindowForContainer(focused);
        BOOL keyWindow = focusedWindow && [focusedWindow respondsToSelector:@selector(isKeyWindow)]
            ? ((BOOL (*)(id, SEL))objc_msgSend)(focusedWindow, @selector(isKeyWindow))
            : NO;
        if (keyWindow || SpliceKit_dualTimelineContainerOwnsActiveModule(focused)) {
            return focused;
        }
    }

    id secondary = SpliceKit_dualTimelineLookupInstalledContainer(kSpliceKitDualEditorContainerID);
    if (SpliceKit_dualTimelineIsUsableContainer(secondary)) {
        id secondaryWindow = SpliceKit_dualTimelineWindowForContainer(secondary);
        if (secondaryWindow && [secondaryWindow respondsToSelector:@selector(isKeyWindow)] &&
            ((BOOL (*)(id, SEL))objc_msgSend)(secondaryWindow, @selector(isKeyWindow))) {
            sFocusedEditorContainer = secondary;
            return secondary;
        }
    }

    id original = SpliceKit_dualTimelineOriginalActiveEditorContainer(self);
    if (SpliceKit_dualTimelineIsUsableContainer(original)) {
        sFocusedEditorContainer = original;
    }
    return original;
}

static void SpliceKit_dualTimelineSwizzledFirstResponderChanged(id self, SEL _cmd, id sender) {
    if (sOriginalEditorContainerFirstResponderChanged) {
        ((void (*)(id, SEL, id))sOriginalEditorContainerFirstResponderChanged)(self, _cmd, sender);
    }

    id window = SpliceKit_dualTimelineWindowForContainer(self);
    if (window && [window respondsToSelector:@selector(isKeyWindow)] &&
        ((BOOL (*)(id, SEL))objc_msgSend)(window, @selector(isKeyWindow)) &&
        SpliceKit_dualTimelineContainerOwnsActiveModule(self) &&
        SpliceKit_dualTimelineEditorModuleForContainer(self)) {
        SpliceKit_dualTimelineSetFocusedContainer(self, NO);
    }
}

static void SpliceKit_dualTimelineSwizzledWindowDidBecomeKey(id self, SEL _cmd, id notification) {
    if (sOriginalEditorContainerWindowDidBecomeKey) {
        ((void (*)(id, SEL, id))sOriginalEditorContainerWindowDidBecomeKey)(self, _cmd, notification);
    }

    if (SpliceKit_dualTimelineEditorModuleForContainer(self)) {
        SpliceKit_dualTimelineSetFocusedContainer(self, YES);
    }
}

static void SpliceKit_dualTimelineSwizzledEditorContainerViewDidLoad(id self, SEL _cmd) {
    if (sOriginalEditorContainerViewDidLoad) {
        ((void (*)(id, SEL))sOriginalEditorContainerViewDidLoad)(self, _cmd);
    }

    SpliceKit_dualTimelineRelaxOuterBrowserWidthConstraintsForContainer(self);
}

static CGSize SpliceKit_dualTimelineSwizzledMediaBrowserViewMinSize(id self, SEL _cmd) {
    if (SpliceKit_dualTimelineModuleBelongsToSecondaryWindow(self)) {
        return CGSizeMake(kSpliceKitDualTimelineSecondaryBrowserPaneMinimumWidth, 182.0);
    }

    if (sOriginalMediaBrowserViewMinSize) {
        return ((CGSize (*)(id, SEL))sOriginalMediaBrowserViewMinSize)(self, _cmd);
    }

    return CGSizeMake(383.0, 182.0);
}

void SpliceKit_installDualTimeline(void) {
    Class appControllerClass = objc_getClass("PEAppController");
    Class editorContainerClass = objc_getClass("PEEditorContainerModule");
    Class mediaBrowserContainerClass = objc_getClass("PEMediaBrowserContainerModule");
    Class contentBrowserClass = objc_getClass("FFContentBrowserModule");
    Class windowModuleClass = objc_getClass("LKWindowModule");
    Class layoutManagerClass = objc_getClass("LKModuleLayoutManager");
    if (!appControllerClass || !editorContainerClass || !mediaBrowserContainerClass || !contentBrowserClass ||
        !windowModuleClass || !layoutManagerClass) {
        SpliceKit_log(@"[DualTimeline] Required classes missing — PEAppController=%@ PEEditorContainerModule=%@ PEMediaBrowserContainerModule=%@ FFContentBrowserModule=%@ LKWindowModule=%@ LKModuleLayoutManager=%@",
                      appControllerClass ? @"YES" : @"NO",
                      editorContainerClass ? @"YES" : @"NO",
                      mediaBrowserContainerClass ? @"YES" : @"NO",
                      contentBrowserClass ? @"YES" : @"NO",
                      windowModuleClass ? @"YES" : @"NO",
                      layoutManagerClass ? @"YES" : @"NO");
        return;
    }

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // The activeEditorContainer swizzle is the critical one — everything else
        // (focus tracking, constraint relaxation) depends on it.  If it fails, bail
        // rather than leaving partial state that corrupts the editor container path.
        sOriginalActiveEditorContainer = SpliceKit_swizzleMethod(
            appControllerClass, @selector(activeEditorContainer),
            (IMP)SpliceKit_dualTimelineSwizzledActiveEditorContainer);
        if (!sOriginalActiveEditorContainer) {
            SpliceKit_log(@"[DualTimeline] activeEditorContainer swizzle failed — aborting install");
            return;
        }

        sOriginalEditorContainerFirstResponderChanged = SpliceKit_swizzleMethod(
            editorContainerClass, NSSelectorFromString(@"firstResponderChanged:"),
            (IMP)SpliceKit_dualTimelineSwizzledFirstResponderChanged);
        sOriginalEditorContainerWindowDidBecomeKey = SpliceKit_swizzleMethod(
            editorContainerClass, NSSelectorFromString(@"windowDidBecomeKey:"),
            (IMP)SpliceKit_dualTimelineSwizzledWindowDidBecomeKey);
        sOriginalEditorContainerViewDidLoad = SpliceKit_swizzleMethod(
            editorContainerClass, @selector(viewDidLoad),
            (IMP)SpliceKit_dualTimelineSwizzledEditorContainerViewDidLoad);
        sOriginalMediaBrowserViewMinSize = SpliceKit_swizzleMethod(
            mediaBrowserContainerClass, @selector(viewMinSize),
            (IMP)SpliceKit_dualTimelineSwizzledMediaBrowserViewMinSize);
        sOriginalContentBrowserConstrainWidth = SpliceKit_swizzleMethod(
            contentBrowserClass, NSSelectorFromString(@"constrainWidth:"),
            (IMP)SpliceKit_dualTimelineSwizzledContentBrowserConstrainWidth);
        sOriginalContentBrowserViewDidLoad = SpliceKit_swizzleMethod(
            contentBrowserClass, @selector(viewDidLoad),
            (IMP)SpliceKit_dualTimelineSwizzledContentBrowserViewDidLoad);
        sOriginalWindowModuleShouldSaveToLayout = SpliceKit_swizzleMethod(
            windowModuleClass, @selector(shouldSaveToLayout),
            (IMP)SpliceKit_dualTimelineSwizzledWindowModuleShouldSaveToLayout);
        sOriginalLayoutManagerExistingModuleFromLayout = SpliceKit_swizzleMethod(
            layoutManagerClass, NSSelectorFromString(@"newExistingRegisteredModuleMatchingLayoutDictionary:"),
            (IMP)SpliceKit_dualTimelineSwizzledExistingModuleFromLayoutDictionary);

        id primary = SpliceKit_dualTimelinePrimaryEditorContainer();
        if (primary) {
            sFocusedEditorContainer = primary;
            SpliceKit_dualTimelineRelaxBrowserWidthConstraintsForContainer(primary);
        }
        sDualTimelineInstalled = YES;
        SpliceKit_log(@"[DualTimeline] Installed focused editor routing swizzles");
    });
}

BOOL SpliceKit_isDualTimelineInstalled(void) {
    return sDualTimelineInstalled;
}

NSString *SpliceKit_dualTimelineSecondaryIdentifier(void) {
    return kSpliceKitDualEditorContainerID;
}

id SpliceKit_dualTimelineFocusedEditorContainer(void) {
    id focused = sFocusedEditorContainer;
    if (SpliceKit_dualTimelineIsUsableContainer(focused)) {
        return focused;
    }

    id secondary = SpliceKit_dualTimelineSecondaryEditorContainer(NO);
    id secondaryWindow = SpliceKit_dualTimelineWindowForContainer(secondary);
    if (secondaryWindow && [secondaryWindow respondsToSelector:@selector(isKeyWindow)] &&
        ((BOOL (*)(id, SEL))objc_msgSend)(secondaryWindow, @selector(isKeyWindow))) {
        sFocusedEditorContainer = secondary;
        return secondary;
    }

    id primary = SpliceKit_dualTimelinePrimaryEditorContainer();
    if (primary) {
        sFocusedEditorContainer = primary;
    }
    return primary;
}

id SpliceKit_dualTimelinePrimaryEditorContainer(void) {
    id appController = SpliceKit_dualTimelineAppController();
    if (!appController) return nil;

    SEL mainEditorContainerSel = NSSelectorFromString(@"mainEditorContainer");
    if ([appController respondsToSelector:mainEditorContainerSel]) {
        id container = ((id (*)(id, SEL))objc_msgSend)(appController, mainEditorContainerSel);
        if (container) return container;
    }

    return SpliceKit_dualTimelineOriginalActiveEditorContainer(appController);
}

id SpliceKit_dualTimelineSecondaryEditorContainer(BOOL createIfNeeded) {
    id existing = SpliceKit_dualTimelineLookupInstalledContainer(kSpliceKitDualEditorContainerID);
    if (existing) {
        SpliceKit_dualTimelineTrackSecondaryWindowModule(existing);
        SpliceKit_dualTimelineRelaxOuterBrowserWidthConstraintsForContainer(existing);
        return existing;
    }
    if (!createIfNeeded) {
        return existing;
    }

    id appController = SpliceKit_dualTimelineAppController();
    if (!appController) return nil;

    SEL createSel = NSSelectorFromString(@"editorContainerWithID:createIfNeeded:withFrame:");
    if (![appController respondsToSelector:createSel]) {
        return nil;
    }

    CGRect frame = SpliceKit_dualTimelineDefaultFrame();
    id container = ((id (*)(id, SEL, id, BOOL, CGRect))objc_msgSend)(
        appController, createSel, kSpliceKitDualEditorContainerID, YES, frame);
    if (container) {
        SpliceKit_dualTimelineTrackSecondaryWindowModule(container);
        SpliceKit_dualTimelineRelaxOuterBrowserWidthConstraintsForContainer(container);
        SpliceKit_log(@"[DualTimeline] Secondary editor container ready");
    }
    return container;
}

NSDictionary *SpliceKit_dualTimelineStatus(void) {
    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        id primary = SpliceKit_dualTimelinePrimaryEditorContainer();
        id secondary = SpliceKit_dualTimelineSecondaryEditorContainer(NO);
        id focused = SpliceKit_dualTimelineFocusedEditorContainer();

        result = @{
            @"secondaryIdentifier": kSpliceKitDualEditorContainerID,
            @"focusedPane": SpliceKit_dualTimelineIdentifierForContainer(focused) ?: @"",
            @"primary": SpliceKit_dualTimelineContainerInfo(primary, @"primary"),
            @"secondary": SpliceKit_dualTimelineContainerInfo(secondary, @"secondary"),
        };
    });
    return result ?: @{@"error": @"Failed to inspect dual timeline state"};
}

NSDictionary *SpliceKit_dualTimelineOpen(NSDictionary *params) {
    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        id sourceContainer = SpliceKit_dualTimelineSourceContainerForParams(params);
        id sourceEditor = SpliceKit_dualTimelineEditorModuleForContainer(sourceContainer);
        id sourceSequence = SpliceKit_dualTimelineSequenceForEditor(sourceEditor);
        if (!sourceSequence) {
            result = @{@"error": @"No source sequence available for the dual timeline"};
            return;
        }

        id secondary = SpliceKit_dualTimelineSecondaryEditorContainer(YES);
        if (!secondary) {
            result = @{@"error": @"Failed to create the secondary editor container"};
            return;
        }

        SpliceKit_dualTimelineLoadSequenceIntoContainer(secondary, sourceSequence);
        SpliceKit_dualTimelineRelaxBrowserWidthConstraintsForContainer(secondary);
        SpliceKit_dualTimelineRelaxOuterBrowserWidthConstraintsForContainer(secondary);

        BOOL focusSecondary = [params[@"focus"] boolValue];
        if (focusSecondary) {
            SpliceKit_dualTimelineFocusWindowForContainer(secondary);
        } else {
            id primary = SpliceKit_dualTimelinePrimaryEditorContainer();
            if (primary) {
                SpliceKit_dualTimelineFocusWindowForContainer(primary);
            }
        }

        result = @{
            @"status": @"ok",
            @"action": @"open",
            @"source": SpliceKit_dualTimelineIdentifierForContainer(sourceContainer) ?: @"",
            @"focusedPane": focusSecondary ? @"secondary" : @"primary",
            @"secondary": SpliceKit_dualTimelineContainerInfo(secondary, @"secondary"),
        };
    });
    return result ?: @{@"error": @"Failed to open the secondary timeline"};
}

NSDictionary *SpliceKit_dualTimelineSyncRoot(NSDictionary *params) {
    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        id sourceContainer = SpliceKit_dualTimelineSourceContainerForParams(params);
        id sourceEditor = SpliceKit_dualTimelineEditorModuleForContainer(sourceContainer);
        id sourceSequence = SpliceKit_dualTimelineSequenceForEditor(sourceEditor);
        id sourceRootItem = SpliceKit_dualTimelineRootItemForEditor(sourceEditor);
        if (!sourceSequence || !sourceRootItem) {
            result = @{@"error": @"No source editor root is available to sync"};
            return;
        }

        id secondary = SpliceKit_dualTimelineSecondaryEditorContainer(YES);
        if (!secondary) {
            result = @{@"error": @"Failed to create the secondary editor container"};
            return;
        }

        SpliceKit_dualTimelineLoadSequenceIntoContainer(secondary, sourceSequence);
        SpliceKit_dualTimelineRelaxBrowserWidthConstraintsForContainer(secondary);
        SpliceKit_dualTimelineRelaxOuterBrowserWidthConstraintsForContainer(secondary);

        id secondaryEditor = SpliceKit_dualTimelineEditorModuleForContainer(secondary);
        id primaryObject = SpliceKit_dualTimelinePrimaryObjectForSequence(sourceSequence);
        if (secondaryEditor && sourceRootItem != primaryObject &&
            [secondaryEditor respondsToSelector:NSSelectorFromString(@"pushRootItem:")]) {
            ((void (*)(id, SEL, id))objc_msgSend)(secondaryEditor, NSSelectorFromString(@"pushRootItem:"), sourceRootItem);
        }

        BOOL focusSecondary = [params[@"focus"] boolValue];
        if (focusSecondary) {
            SpliceKit_dualTimelineFocusWindowForContainer(secondary);
        } else {
            id primary = SpliceKit_dualTimelinePrimaryEditorContainer();
            if (primary) {
                SpliceKit_dualTimelineFocusWindowForContainer(primary);
            }
        }

        result = @{
            @"status": @"ok",
            @"action": @"syncRoot",
            @"source": SpliceKit_dualTimelineIdentifierForContainer(sourceContainer) ?: @"",
            @"rootName": [sourceRootItem respondsToSelector:@selector(displayName)]
                ? (((id (*)(id, SEL))objc_msgSend)(sourceRootItem, @selector(displayName)) ?: @"")
                : @"",
            @"secondary": SpliceKit_dualTimelineContainerInfo(secondary, @"secondary"),
        };
    });
    return result ?: @{@"error": @"Failed to sync the secondary root"};
}

NSDictionary *SpliceKit_dualTimelineOpenSelectedInSecondary(NSDictionary *params) {
    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        id sourceContainer = SpliceKit_dualTimelineSourceContainerForParams(params);
        id sourceTimeline = SpliceKit_dualTimelineTimelineModuleForContainer(sourceContainer);
        id sourceEditor = SpliceKit_dualTimelineEditorModuleForContainer(sourceContainer);
        id sourceSequence = SpliceKit_dualTimelineSequenceForEditor(sourceEditor);
        if (!sourceTimeline || !sourceSequence) {
            result = @{@"error": @"No source timeline is available"};
            return;
        }

        NSArray *selectedItems = SpliceKit_dualTimelineSelectedItemsForTimeline(sourceTimeline);
        id selectedItem = selectedItems.firstObject;
        if (!selectedItem) {
            result = @{@"error": @"Select a compound clip, multicam angle, or related item first"};
            return;
        }

        id secondary = SpliceKit_dualTimelineSecondaryEditorContainer(YES);
        if (!secondary) {
            result = @{@"error": @"Failed to create the secondary editor container"};
            return;
        }

        SpliceKit_dualTimelineLoadSequenceIntoContainer(secondary, sourceSequence);
        SpliceKit_dualTimelineRelaxBrowserWidthConstraintsForContainer(secondary);
        SpliceKit_dualTimelineRelaxOuterBrowserWidthConstraintsForContainer(secondary);

        id secondaryTimeline = SpliceKit_dualTimelineTimelineModuleForContainer(secondary);
        SEL openInTimelineSel = NSSelectorFromString(@"openInTimeline:");
        if (!secondaryTimeline || ![secondaryTimeline respondsToSelector:openInTimelineSel]) {
            result = @{@"error": @"Secondary timeline does not support openInTimeline:"};
            return;
        }

        ((void (*)(id, SEL, id))objc_msgSend)(secondaryTimeline, openInTimelineSel, selectedItem);

        BOOL focusSecondary = params[@"focus"] ? [params[@"focus"] boolValue] : YES;
        if (focusSecondary) {
            SpliceKit_dualTimelineFocusWindowForContainer(secondary);
        } else {
            id primary = SpliceKit_dualTimelinePrimaryEditorContainer();
            if (primary) {
                SpliceKit_dualTimelineFocusWindowForContainer(primary);
            }
        }

        NSString *selectedName = [selectedItem respondsToSelector:@selector(displayName)]
            ? (((id (*)(id, SEL))objc_msgSend)(selectedItem, @selector(displayName)) ?: @"")
            : @"";

        result = @{
            @"status": @"ok",
            @"action": @"openSelectedInSecondary",
            @"selectedItemName": selectedName,
            @"secondary": SpliceKit_dualTimelineContainerInfo(secondary, @"secondary"),
        };
    });
    return result ?: @{@"error": @"Failed to open the selected item in the secondary timeline"};
}

NSDictionary *SpliceKit_dualTimelineFocus(NSDictionary *params) {
    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        NSString *pane = [params[@"pane"] isKindOfClass:[NSString class]] ? params[@"pane"] : @"primary";
        id container = [pane isEqualToString:@"secondary"]
            ? SpliceKit_dualTimelineSecondaryEditorContainer(NO)
            : SpliceKit_dualTimelinePrimaryEditorContainer();
        if (!container) {
            result = @{@"error": [NSString stringWithFormat:@"No %@ editor container is available", pane]};
            return;
        }

        SpliceKit_dualTimelineFocusWindowForContainer(container);
        result = @{
            @"status": @"ok",
            @"action": @"focus",
            @"pane": pane,
            @"focusedPane": SpliceKit_dualTimelineIdentifierForContainer(container) ?: pane,
        };
    });
    return result ?: @{@"error": @"Failed to focus the requested timeline"};
}

NSDictionary *SpliceKit_dualTimelineClose(NSDictionary *params) {
    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        id secondary = SpliceKit_dualTimelineSecondaryEditorContainer(NO);
        if (!secondary) {
            result = @{@"status": @"ok", @"action": @"close", @"message": @"Secondary timeline is already closed"};
            return;
        }

        id window = SpliceKit_dualTimelineWindowForContainer(secondary);
        if (window && [window respondsToSelector:@selector(close)]) {
            ((void (*)(id, SEL))objc_msgSend)(window, @selector(close));
        }
        sSecondaryContentBrowserModule = nil;
        sSecondaryRootWindowModule = nil;

        id primary = SpliceKit_dualTimelinePrimaryEditorContainer();
        BOOL focusPrimary = params[@"focusPrimary"] ? [params[@"focusPrimary"] boolValue] : YES;
        if (focusPrimary && primary) {
            SpliceKit_dualTimelineFocusWindowForContainer(primary);
        } else if (sFocusedEditorContainer == secondary) {
            sFocusedEditorContainer = primary;
        }

        result = @{
            @"status": @"ok",
            @"action": @"close",
            @"focusedPane": primary ? @"primary" : @"",
        };
    });
    return result ?: @{@"error": @"Failed to close the secondary timeline"};
}

NSDictionary *SpliceKit_dualTimelineTogglePanel(NSDictionary *params) {
    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        NSString *panel = [params[@"panel"] isKindOfClass:[NSString class]] ? params[@"panel"] : nil;
        if (panel.length == 0) {
            result = @{@"error": @"panel parameter required"};
            return;
        }

        NSString *pane = [params[@"pane"] isKindOfClass:[NSString class]] ? params[@"pane"] : @"secondary";
        id container = [pane isEqualToString:@"primary"]
            ? SpliceKit_dualTimelinePrimaryEditorContainer()
            : SpliceKit_dualTimelineSecondaryEditorContainer(NO);
        if (!container) {
            result = @{@"error": [NSString stringWithFormat:@"No %@ editor container is available", pane]};
            return;
        }

        if ([panel isEqualToString:@"browser"]) {
            id submodule = [container respondsToSelector:NSSelectorFromString(@"browserModule")]
                ? ((id (*)(id, SEL))objc_msgSend)(container, NSSelectorFromString(@"browserModule"))
                : nil;
            result = SpliceKit_dualTimelineToggleSubmodule(container, submodule, panel);
            SpliceKit_dualTimelineRelaxBrowserWidthConstraintsForContainer(container);
            return;
        }
        if ([panel isEqualToString:@"timelineIndex"]) {
            id submodule = [container respondsToSelector:NSSelectorFromString(@"timelineIndex")]
                ? ((id (*)(id, SEL))objc_msgSend)(container, NSSelectorFromString(@"timelineIndex"))
                : nil;
            result = SpliceKit_dualTimelineToggleSubmodule(container, submodule, panel);
            return;
        }
        if ([panel isEqualToString:@"audioMeters"]) {
            id submodule = [container respondsToSelector:NSSelectorFromString(@"audioMeterModule")]
                ? ((id (*)(id, SEL))objc_msgSend)(container, NSSelectorFromString(@"audioMeterModule"))
                : nil;
            result = SpliceKit_dualTimelineToggleSubmodule(container, submodule, panel);
            return;
        }
        if ([panel isEqualToString:@"effectsBrowser"]) {
            result = SpliceKit_dualTimelineToggleMediaBrowserMode(container, 0, panel);
            return;
        }
        if ([panel isEqualToString:@"transitionsBrowser"]) {
            result = SpliceKit_dualTimelineToggleMediaBrowserMode(container, 1, panel);
            return;
        }

        result = @{@"error": [NSString stringWithFormat:
            @"Unsupported dual timeline panel '%@'. Available: browser, timelineIndex, audioMeters, effectsBrowser, transitionsBrowser",
            panel]};
    });
    return result ?: @{@"error": @"Failed to toggle dual timeline panel"};
}
