//
//  SpliceKitAudioBusDiagnostics.m
//  Live probes for FCP's role/audio scoping window graph.
//

#import "SpliceKit.h"

static IMP sOriginalAddScopingWindow = NULL;
static IMP sOriginalEnumerateScopingWindows = NULL;
static BOOL sAudioBusDiagnosticsInstalled = NO;
static BOOL sAudioBusDiagnosticsEnabled = NO;
static BOOL sAudioBusDiagnosticsIncludeStacks = NO;
static BOOL sAudioBusDiagnosticsStoreHandles = NO;
static NSUInteger sAudioBusDiagnosticsMaxEvents = 200;
static NSUInteger sAudioBusDiagnosticsSequence = 0;
static NSMutableArray<NSDictionary *> *sAudioBusDiagnosticsEvents = nil;

static NSObject *SpliceKitAudioBusDiagnosticsLock(void) {
    static NSObject *lock = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        lock = [NSObject new];
        sAudioBusDiagnosticsEvents = [NSMutableArray array];
    });
    return lock;
}

static NSString *SpliceKitAudioBusPointerString(const void *ptr) {
    return ptr ? [NSString stringWithFormat:@"%p", ptr] : @"";
}

static void SpliceKitAudioBusSetIfPresent(NSMutableDictionary *dict, NSString *key, id value) {
    if (!dict || key.length == 0 || !value) return;
    dict[key] = value;
}

static id SpliceKitAudioBusObjectAtOffset(void *base, ptrdiff_t offset) {
    if (!base) return nil;
    __unsafe_unretained id object = nil;
    memcpy(&object, ((char *)base) + offset, sizeof(object));
    return object;
}

static void *SpliceKitAudioBusPointerAtOffset(void *base, ptrdiff_t offset) {
    if (!base) return NULL;
    void *value = NULL;
    memcpy(&value, ((char *)base) + offset, sizeof(value));
    return value;
}

static NSNumber *SpliceKitAudioBusByteAtOffset(void *base, ptrdiff_t offset) {
    if (!base) return @NO;
    uint8_t value = 0;
    memcpy(&value, ((char *)base) + offset, sizeof(value));
    return @(value != 0);
}

static NSNumber *SpliceKitAudioBusUInt64AtOffset(void *base, ptrdiff_t offset) {
    if (!base) return @(0);
    uint64_t value = 0;
    memcpy(&value, ((char *)base) + offset, sizeof(value));
    return @(value);
}

static id SpliceKitAudioBusSendObject(id object, NSString *selectorName) {
    if (!object || selectorName.length == 0) return nil;
    @try {
        SEL selector = NSSelectorFromString(selectorName);
        if (![object respondsToSelector:selector]) return nil;
        return ((id (*)(id, SEL))objc_msgSend)(object, selector);
    } @catch (NSException *exception) {
        return nil;
    }
}

static void *SpliceKitAudioBusSendPointer(id object, NSString *selectorName) {
    if (!object || selectorName.length == 0) return NULL;
    @try {
        SEL selector = NSSelectorFromString(selectorName);
        if (![object respondsToSelector:selector]) return NULL;
        return ((void *(*)(id, SEL))objc_msgSend)(object, selector);
    } @catch (NSException *exception) {
        return NULL;
    }
}

static void SpliceKitAudioBusSendVoidBool(id object, NSString *selectorName, BOOL value) {
    if (!object || selectorName.length == 0) return;
    @try {
        SEL selector = NSSelectorFromString(selectorName);
        if (![object respondsToSelector:selector]) return;
        ((void (*)(id, SEL, BOOL))objc_msgSend)(object, selector, value);
    } @catch (NSException *exception) {
    }
}

static NSNumber *SpliceKitAudioBusSendBool(id object, NSString *selectorName) {
    if (!object || selectorName.length == 0) return nil;
    @try {
        SEL selector = NSSelectorFromString(selectorName);
        if (![object respondsToSelector:selector]) return nil;
        BOOL value = ((BOOL (*)(id, SEL))objc_msgSend)(object, selector);
        return @(value);
    } @catch (NSException *exception) {
        return nil;
    }
}

static NSNumber *SpliceKitAudioBusSendUInt64(id object, NSString *selectorName) {
    if (!object || selectorName.length == 0) return nil;
    @try {
        SEL selector = NSSelectorFromString(selectorName);
        if (![object respondsToSelector:selector]) return nil;
        unsigned long long value = ((unsigned long long (*)(id, SEL))objc_msgSend)(object, selector);
        return @(value);
    } @catch (NSException *exception) {
        return nil;
    }
}

static id SpliceKitAudioBusAudioEffectsForIdentifier(id object, unsigned long long identifier) {
    if (!object) return nil;
    @try {
        SEL selector = NSSelectorFromString(@"audioEffectsForIdentifier:");
        if (![object respondsToSelector:selector]) return nil;
        return ((id (*)(id, SEL, unsigned long long))objc_msgSend)(object, selector, identifier);
    } @catch (NSException *exception) {
        return nil;
    }
}

static NSArray *SpliceKitAudioBusArrayFromContainer(id container) {
    if (!container) return @[];
    if ([container isKindOfClass:[NSArray class]]) return container;
    if ([container isKindOfClass:[NSSet class]]) return [(NSSet *)container allObjects];
    if ([container isKindOfClass:[NSOrderedSet class]]) return [(NSOrderedSet *)container array];
    id allObjects = SpliceKitAudioBusSendObject(container, @"allObjects");
    if ([allObjects isKindOfClass:[NSArray class]]) return allObjects;
    return @[];
}

static NSString *SpliceKitAudioBusStringValue(id value) {
    if (!value) return nil;
    if ([value isKindOfClass:[NSString class]]) return value;
    if ([value isKindOfClass:[NSNumber class]]) return [(NSNumber *)value stringValue];
    @try {
        NSString *description = [value description];
        return description.length > 0 ? description : nil;
    } @catch (NSException *exception) {
        return nil;
    }
}

static NSMutableDictionary *SpliceKitAudioBusObjectSummary(id object) {
    NSMutableDictionary *summary = [NSMutableDictionary dictionary];
    if (!object) return summary;

    @try {
        summary[@"pointer"] = SpliceKitAudioBusPointerString((__bridge const void *)object);
        summary[@"class"] = NSStringFromClass([object class]) ?: @"";
        if (sAudioBusDiagnosticsStoreHandles) {
            NSString *handle = SpliceKit_storeHandle(object);
            if (handle.length > 0) summary[@"handle"] = handle;
        }
    } @catch (NSException *exception) {
        summary[@"pointer"] = SpliceKitAudioBusPointerString((__bridge const void *)object);
        return summary;
    }

    for (NSString *selectorName in @[@"displayName", @"name", @"audioRoleIdentifier",
                                     @"guessAudioBuiltInMainRoleUID", @"uid",
                                     @"identifier", @"roleIdentifier"]) {
        NSString *value = SpliceKitAudioBusStringValue(SpliceKitAudioBusSendObject(object, selectorName));
        if (value.length > 0) summary[selectorName] = value;
    }

    for (NSString *selectorName in @[@"hasAudio", @"isProject", @"isSpine", @"isMediaRef",
                                     @"isComponent", @"isAudioComponentSource",
                                     @"isDefaultAudioEffectStack", @"hasAudioRetimingEffects"]) {
        NSNumber *value = SpliceKitAudioBusSendBool(object, selectorName);
        if (value) summary[selectorName] = value;
    }

    return summary;
}

static NSDictionary *SpliceKitAudioBusEffectStackSummary(id effectStack) {
    NSMutableDictionary *summary = SpliceKitAudioBusObjectSummary(effectStack);
    if (!effectStack) return summary;

    id audioLevelChannel = SpliceKitAudioBusSendObject(effectStack, @"audioLevelChannel");
    if (audioLevelChannel) {
        summary[@"audioLevelChannel"] = SpliceKitAudioBusObjectSummary(audioLevelChannel);
    }

    for (NSString *selectorName in @[@"effects", @"effectItems", @"allEffects", @"externalEffects"]) {
        id value = SpliceKitAudioBusSendObject(effectStack, selectorName);
        NSArray *items = SpliceKitAudioBusArrayFromContainer(value);
        if (items.count > 0) {
            NSMutableArray *effectSummaries = [NSMutableArray arrayWithCapacity:items.count];
            for (id item in items) {
                [effectSummaries addObject:SpliceKitAudioBusObjectSummary(item)];
            }
            summary[selectorName] = effectSummaries;
        }
    }

    return summary;
}

static NSArray<NSDictionary *> *SpliceKitAudioBusRoleSummaries(id rolesContainer) {
    NSArray *roles = SpliceKitAudioBusArrayFromContainer(rolesContainer);
    NSMutableArray *summaries = [NSMutableArray arrayWithCapacity:roles.count];
    for (id role in roles) {
        [summaries addObject:SpliceKitAudioBusObjectSummary(role)];
    }
    return summaries;
}

static NSDictionary *SpliceKitAudioBusStreamOptionsSummary(id options) {
    NSMutableDictionary *summary = SpliceKitAudioBusObjectSummary(options);
    if (!options) return summary;

    for (NSString *selectorName in @[@"streamAudioFlags", @"streamAudioPrivateFlags",
                                     @"channelValenceID", @"numChannels",
                                     @"audioChannelCount"]) {
        NSNumber *value = SpliceKitAudioBusSendUInt64(options, selectorName);
        if (value) summary[selectorName] = value;
    }

    id playRoles = SpliceKitAudioBusSendObject(options, @"playRoles");
    NSArray *roleSummaries = SpliceKitAudioBusRoleSummaries(playRoles);
    if (roleSummaries.count > 0) summary[@"playRoles"] = roleSummaries;

    id audioEffects = SpliceKitAudioBusSendObject(options, @"audioEffects");
    if (audioEffects) summary[@"audioEffects"] = SpliceKitAudioBusEffectStackSummary(audioEffects);

    id componentsPlaybackInfo = SpliceKitAudioBusSendObject(options, @"componentsPlaybackInfo");
    if (componentsPlaybackInfo) {
        summary[@"componentsPlaybackInfo"] = SpliceKitAudioBusObjectSummary(componentsPlaybackInfo);
        if ([componentsPlaybackInfo isKindOfClass:[NSDictionary class]]) {
            summary[@"componentsPlaybackInfoKeys"] = [(NSDictionary *)componentsPlaybackInfo allKeys];
        }
    }

    return summary;
}

static NSDictionary *SpliceKitAudioBusRootObjectSummary(id rootObject) {
    NSMutableDictionary *summary = SpliceKitAudioBusObjectSummary(rootObject);
    if (!rootObject) return summary;

    id localAudioEffects = SpliceKitAudioBusSendObject(rootObject, @"localAudioEffects");
    if (localAudioEffects) {
        summary[@"localAudioEffects"] = SpliceKitAudioBusEffectStackSummary(localAudioEffects);
    }

    id identifier0Effects = SpliceKitAudioBusAudioEffectsForIdentifier(rootObject, 0);
    if (identifier0Effects) {
        summary[@"audioEffectsForIdentifier0"] = SpliceKitAudioBusEffectStackSummary(identifier0Effects);
    }

    id identifier4Effects = SpliceKitAudioBusAudioEffectsForIdentifier(rootObject, 4);
    if (identifier4Effects) {
        summary[@"audioEffectsForIdentifier4"] = SpliceKitAudioBusEffectStackSummary(identifier4Effects);
    }

    id layoutMap = SpliceKitAudioBusSendObject(rootObject, @"audioComponentsLayoutMap");
    if (layoutMap) {
        NSMutableDictionary *layoutSummary = SpliceKitAudioBusObjectSummary(layoutMap);
        NSNumber *enabled = SpliceKitAudioBusSendBool(layoutMap, @"isLayoutMapEnabled");
        if (enabled) layoutSummary[@"isLayoutMapEnabled"] = enabled;
        summary[@"audioComponentsLayoutMap"] = layoutSummary;
    }

    return summary;
}

static NSDictionary *SpliceKitAudioBusDescribeScopingWindow(void *window) {
    NSMutableDictionary *event = [NSMutableDictionary dictionary];
    if (!window) return event;

    event[@"scopingWindowPointer"] = SpliceKitAudioBusPointerString(window);
    event[@"topLevelScopingWindow"] = SpliceKitAudioBusByteAtOffset(window, 16);
    event[@"topLevelMixBusScopingWindow"] = SpliceKitAudioBusByteAtOffset(window, 17);
    event[@"componentPlaybackWindow"] = SpliceKitAudioBusByteAtOffset(window, 18);
    event[@"registeredWithMediator"] = SpliceKitAudioBusByteAtOffset(window, 20);
    event[@"wantsEffectsBus"] = SpliceKitAudioBusByteAtOffset(window, 505);
    event[@"cachedStreamAudioFlagsAt568"] = SpliceKitAudioBusUInt64AtOffset(window, 568);

    id rootObject = SpliceKitAudioBusObjectAtOffset(window, 480);
    id delegateObject = SpliceKitAudioBusObjectAtOffset(window, 488);
    id componentsPlaybackInfo = SpliceKitAudioBusObjectAtOffset(window, 576);
    void *bus = SpliceKitAudioBusPointerAtOffset(window, 584);
    id stream = SpliceKitAudioBusObjectAtOffset(window, 624);

    if (rootObject) event[@"rootObject"] = SpliceKitAudioBusRootObjectSummary(rootObject);
    if (delegateObject) event[@"delegateObject"] = SpliceKitAudioBusObjectSummary(delegateObject);
    if (componentsPlaybackInfo) event[@"windowComponentsPlaybackInfo"] = SpliceKitAudioBusObjectSummary(componentsPlaybackInfo);
    if (bus) event[@"audioBusPointer"] = SpliceKitAudioBusPointerString(bus);
    if (stream) {
        NSMutableDictionary *streamSummary = SpliceKitAudioBusObjectSummary(stream);
        id streamOptions = SpliceKitAudioBusSendObject(stream, @"audioStreamOptions");
        if (streamOptions) {
            streamSummary[@"audioStreamOptions"] = SpliceKitAudioBusStreamOptionsSummary(streamOptions);
        }
        id source = SpliceKitAudioBusSendObject(stream, @"source");
        if (source) streamSummary[@"source"] = SpliceKitAudioBusObjectSummary(source);
        event[@"stream"] = streamSummary;
    }

    if (sAudioBusDiagnosticsIncludeStacks) {
        NSArray *stack = [NSThread callStackSymbols];
        if (stack.count > 0) {
            event[@"callStack"] = [stack subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)18, stack.count))];
        }
    }

    return event;
}

static void *SpliceKitAudioBusPointerValue(id object) {
    if (!object) return NULL;
    @try {
        SEL selector = NSSelectorFromString(@"pointerValue");
        if (![object respondsToSelector:selector]) return NULL;
        return ((void *(*)(id, SEL))objc_msgSend)(object, selector);
    } @catch (NSException *exception) {
        return NULL;
    }
}

static NSDictionary *SpliceKitAudioBusMapTableSummary(id mapTable,
                                                      NSString *kind,
                                                      BOOL keyIsScopingWindowValue,
                                                      BOOL valueIsScopingWindowValueArray,
                                                      NSUInteger limit) {
    NSMutableDictionary *summary = SpliceKitAudioBusObjectSummary(mapTable);
    summary[@"kind"] = kind ?: @"map";
    if (!mapTable) return summary;

    NSNumber *count = SpliceKitAudioBusSendUInt64(mapTable, @"count");
    if (count) summary[@"count"] = count;

    id keyEnumerator = SpliceKitAudioBusSendObject(mapTable, @"keyEnumerator");
    if (!keyEnumerator) return summary;

    NSMutableArray *entries = [NSMutableArray array];
    while (entries.count < limit) {
        id key = SpliceKitAudioBusSendObject(keyEnumerator, @"nextObject");
        if (!key) break;

        id value = nil;
        @try {
            SEL objectForKey = NSSelectorFromString(@"objectForKey:");
            if ([mapTable respondsToSelector:objectForKey]) {
                value = ((id (*)(id, SEL, id))objc_msgSend)(mapTable, objectForKey, key);
            }
        } @catch (NSException *exception) {
        }

        NSMutableDictionary *entry = [NSMutableDictionary dictionary];
        if (keyIsScopingWindowValue) {
            void *window = SpliceKitAudioBusPointerValue(key);
            entry[@"key"] = SpliceKitAudioBusObjectSummary(key);
            if (window) entry[@"scopingWindow"] = SpliceKitAudioBusDescribeScopingWindow(window);
        } else {
            entry[@"key"] = SpliceKitAudioBusObjectSummary(key);
        }

        if (valueIsScopingWindowValueArray) {
            NSArray *values = SpliceKitAudioBusArrayFromContainer(value);
            NSMutableArray *windows = [NSMutableArray arrayWithCapacity:values.count];
            for (id pointerValue in values) {
                void *window = SpliceKitAudioBusPointerValue(pointerValue);
                if (window) {
                    [windows addObject:SpliceKitAudioBusDescribeScopingWindow(window)];
                } else {
                    [windows addObject:SpliceKitAudioBusObjectSummary(pointerValue)];
                }
            }
            entry[@"valueWindows"] = windows;
        } else {
            entry[@"value"] = SpliceKitAudioBusObjectSummary(value);
        }

        [entries addObject:entry];
    }
    summary[@"entries"] = entries;
    summary[@"truncated"] = @([count unsignedIntegerValue] > entries.count);
    return summary;
}

static NSDictionary *SpliceKitAudioBusMediatorState(NSDictionary *params) {
    NSUInteger limit = 40;
    NSNumber *limitParam = [params[@"limit"] isKindOfClass:[NSNumber class]] ? params[@"limit"] : nil;
    if (limitParam) limit = MAX((NSUInteger)1, [limitParam unsignedIntegerValue]);

    NSMutableDictionary *state = [NSMutableDictionary dictionary];
    id timeline = SpliceKit_getActiveTimelineModule();
    if (!timeline) return @{@"error": @"No active timeline module"};
    state[@"timeline"] = SpliceKitAudioBusObjectSummary(timeline);

    id player = SpliceKitAudioBusSendObject(timeline, @"player");
    if (!player) return @{@"error": @"No timeline player", @"timeline": state[@"timeline"] ?: @{}};
    state[@"player"] = SpliceKitAudioBusObjectSummary(player);

    id context = SpliceKitAudioBusSendObject(player, @"playbackContext");
    if (!context) return @{@"error": @"No playback context", @"player": state[@"player"] ?: @{}};
    state[@"playbackContext"] = SpliceKitAudioBusObjectSummary(context);
    NSNumber *hasTopLevel = SpliceKitAudioBusSendBool(context, @"hasTopLevelScopingWindow");
    NSNumber *hasTopLevelMix = SpliceKitAudioBusSendBool(context, @"hasTopLevelMixBussScopingWindow");
    if (hasTopLevel) state[@"hasTopLevelScopingWindow"] = hasTopLevel;
    if (hasTopLevelMix) state[@"hasTopLevelMixBussScopingWindow"] = hasTopLevelMix;

    void *mediator = SpliceKitAudioBusSendPointer(context, @"audioPlaybackMediator");
    if (!mediator) {
        SpliceKitAudioBusSendVoidBool(context, @"demandAudioPlaybackMediator:", YES);
        mediator = SpliceKitAudioBusSendPointer(context, @"audioPlaybackMediator");
    }
    if (!mediator) {
        state[@"audioPlaybackMediatorPointer"] = @"";
        state[@"error"] = @"No audio playback mediator";
        return state;
    }

    state[@"audioPlaybackMediatorPointer"] = SpliceKitAudioBusPointerString(mediator);
    state[@"liveUpdateEnabledByte104"] = SpliceKitAudioBusByteAtOffset(mediator, 104);

    id scopingWindowPathMap = SpliceKitAudioBusObjectAtOffset(mediator, 112);
    id objectPathMap = SpliceKitAudioBusObjectAtOffset(mediator, 120);
    id objectScopingWindowMap = SpliceKitAudioBusObjectAtOffset(mediator, 128);
    id effectChainMap = SpliceKitAudioBusObjectAtOffset(mediator, 136);
    id prerollPathStack = SpliceKitAudioBusObjectAtOffset(mediator, 160);
    id updateObjects = SpliceKitAudioBusObjectAtOffset(mediator, 168);

    state[@"scopingWindowPathMap"] = SpliceKitAudioBusMapTableSummary(
        scopingWindowPathMap, @"scopingWindowPointerToPath", YES, NO, limit);
    state[@"objectPathMap"] = SpliceKitAudioBusMapTableSummary(
        objectPathMap, @"anchoredObjectToScopingWindowPaths", NO, NO, limit);
    state[@"objectScopingWindowMap"] = SpliceKitAudioBusMapTableSummary(
        objectScopingWindowMap, @"delegateObjectToScopingWindows", NO, YES, limit);
    state[@"effectChainMap"] = SpliceKitAudioBusMapTableSummary(
        effectChainMap, @"effectStackToAudioEffectChainRegistry", NO, NO, limit);
    state[@"prerollPathStack"] = SpliceKitAudioBusObjectSummary(prerollPathStack);
    state[@"updateObjects"] = SpliceKitAudioBusObjectSummary(updateObjects);
    return state;
}

static void SpliceKitAudioBusRecordScopingWindow(id list, void *window, NSString *kind) {
    if (!sAudioBusDiagnosticsEnabled || !window) return;

    @autoreleasepool {
        NSDictionary *windowDescription = SpliceKitAudioBusDescribeScopingWindow(window);
        NSMutableDictionary *event = windowDescription
            ? [windowDescription mutableCopy]
            : [NSMutableDictionary dictionary];
        event[@"kind"] = kind ?: @"scopingWindow";
        event[@"windowListPointer"] = SpliceKitAudioBusPointerString((__bridge const void *)list);
        event[@"timestamp"] = @([[NSDate date] timeIntervalSince1970]);
        event[@"thread"] = [NSThread currentThread].name.length > 0
            ? [NSThread currentThread].name
            : ([NSThread isMainThread] ? @"main" : @"background");

        @synchronized (SpliceKitAudioBusDiagnosticsLock()) {
            sAudioBusDiagnosticsSequence += 1;
            event[@"sequence"] = @(sAudioBusDiagnosticsSequence);
            [sAudioBusDiagnosticsEvents addObject:event];
            while (sAudioBusDiagnosticsEvents.count > sAudioBusDiagnosticsMaxEvents) {
                [sAudioBusDiagnosticsEvents removeObjectAtIndex:0];
            }
        }
    }
}

static void SpliceKitAudioBusDiagnostics_addScopingWindow(id self, SEL _cmd, void *window) {
    if (sOriginalAddScopingWindow) {
        ((void (*)(id, SEL, void *))sOriginalAddScopingWindow)(self, _cmd, window);
    }
    SpliceKitAudioBusRecordScopingWindow(self, window, @"addScopingWindow");
}

static void SpliceKitAudioBusDiagnostics_enumerateScopingWindows(id self, SEL _cmd, id block) {
    if (!sOriginalEnumerateScopingWindows) return;
    if (!block) {
        ((void (*)(id, SEL, id))sOriginalEnumerateScopingWindows)(self, _cmd, block);
        return;
    }

    void (^wrappedBlock)(void *, BOOL *) = ^(void *window, BOOL *stop) {
        SpliceKitAudioBusRecordScopingWindow(self, window, @"enumerateScopingWindows");
        ((void (^)(void *, BOOL *))block)(window, stop);
    };
    ((void (*)(id, SEL, id))sOriginalEnumerateScopingWindows)(self, _cmd, wrappedBlock);
}

static BOOL SpliceKitAudioBusDiagnosticsInstall(void) {
    @synchronized (SpliceKitAudioBusDiagnosticsLock()) {
        if (sAudioBusDiagnosticsInstalled) return YES;
    }

    Class cls = NSClassFromString(@"FFAudioDynamicScopingWindowList");
    SEL addSelector = NSSelectorFromString(@"addScopingWindow:");
    SEL enumerateSelector = NSSelectorFromString(@"enumerateScopingWindowsUsingBlock:");
    if (!cls || !class_getInstanceMethod(cls, addSelector)) {
        SpliceKit_log(@"[AudioBusDiagnostics] FFAudioDynamicScopingWindowList.addScopingWindow: not found");
        return NO;
    }
    if (!class_getInstanceMethod(cls, enumerateSelector)) {
        SpliceKit_log(@"[AudioBusDiagnostics] FFAudioDynamicScopingWindowList.enumerateScopingWindowsUsingBlock: not found");
        return NO;
    }

    IMP originalAdd = SpliceKit_swizzleMethod(cls, addSelector, (IMP)SpliceKitAudioBusDiagnostics_addScopingWindow);
    IMP originalEnumerate = SpliceKit_swizzleMethod(cls, enumerateSelector, (IMP)SpliceKitAudioBusDiagnostics_enumerateScopingWindows);
    if (!originalAdd || !originalEnumerate) {
        if (originalAdd) SpliceKit_unswizzleMethod(cls, addSelector);
        if (originalEnumerate) SpliceKit_unswizzleMethod(cls, enumerateSelector);
        return NO;
    }

    @synchronized (SpliceKitAudioBusDiagnosticsLock()) {
        sOriginalAddScopingWindow = originalAdd;
        sOriginalEnumerateScopingWindows = originalEnumerate;
        sAudioBusDiagnosticsInstalled = YES;
    }

    SpliceKit_log(@"[AudioBusDiagnostics] Installed scoping window probes");
    return YES;
}

NSDictionary *SpliceKit_handleAudioBusDiagnostics(NSString *method, NSDictionary *params) {
    NSString *action = nil;
    if ([method hasPrefix:@"audioBusDiagnostics."]) {
        action = [method substringFromIndex:[@"audioBusDiagnostics." length]];
    }
    if (action.length == 0 && [params[@"action"] isKindOfClass:[NSString class]]) {
        action = params[@"action"];
    }
    if (action.length == 0) action = @"state";

    if ([action isEqualToString:@"install"]) {
        BOOL installed = SpliceKitAudioBusDiagnosticsInstall();
        return @{@"installed": @(installed)};
    }

    if ([action isEqualToString:@"start"]) {
        BOOL installed = SpliceKitAudioBusDiagnosticsInstall();
        if (!installed) return @{@"error": @"Could not install audio bus diagnostics"};

        NSNumber *maxEvents = [params[@"maxEvents"] isKindOfClass:[NSNumber class]] ? params[@"maxEvents"] : nil;
        NSNumber *includeStacks = [params[@"includeStacks"] isKindOfClass:[NSNumber class]] ? params[@"includeStacks"] : nil;
        NSNumber *storeHandles = [params[@"storeHandles"] isKindOfClass:[NSNumber class]] ? params[@"storeHandles"] : nil;

        @synchronized (SpliceKitAudioBusDiagnosticsLock()) {
            [sAudioBusDiagnosticsEvents removeAllObjects];
            sAudioBusDiagnosticsMaxEvents = maxEvents ? MAX((NSUInteger)1, [maxEvents unsignedIntegerValue]) : 200;
            sAudioBusDiagnosticsIncludeStacks = includeStacks ? [includeStacks boolValue] : NO;
            sAudioBusDiagnosticsStoreHandles = storeHandles ? [storeHandles boolValue] : NO;
            sAudioBusDiagnosticsEnabled = YES;
        }

        SpliceKit_log(@"[AudioBusDiagnostics] Started maxEvents=%lu includeStacks=%@ storeHandles=%@",
                      (unsigned long)sAudioBusDiagnosticsMaxEvents,
                      sAudioBusDiagnosticsIncludeStacks ? @"yes" : @"no",
                      sAudioBusDiagnosticsStoreHandles ? @"yes" : @"no");
        return @{@"status": @"started",
                 @"installed": @YES,
                 @"maxEvents": @(sAudioBusDiagnosticsMaxEvents),
                 @"includeStacks": @(sAudioBusDiagnosticsIncludeStacks),
                 @"storeHandles": @(sAudioBusDiagnosticsStoreHandles)};
    }

    if ([action isEqualToString:@"stop"]) {
        @synchronized (SpliceKitAudioBusDiagnosticsLock()) {
            sAudioBusDiagnosticsEnabled = NO;
        }
        return @{@"status": @"stopped"};
    }

    if ([action isEqualToString:@"clear"]) {
        @synchronized (SpliceKitAudioBusDiagnosticsLock()) {
            [sAudioBusDiagnosticsEvents removeAllObjects];
        }
        return @{@"status": @"cleared"};
    }

    if ([action isEqualToString:@"state"]) {
        @synchronized (SpliceKitAudioBusDiagnosticsLock()) {
            return @{@"installed": @(sAudioBusDiagnosticsInstalled),
                     @"enabled": @(sAudioBusDiagnosticsEnabled),
                     @"includeStacks": @(sAudioBusDiagnosticsIncludeStacks),
                     @"storeHandles": @(sAudioBusDiagnosticsStoreHandles),
                     @"maxEvents": @(sAudioBusDiagnosticsMaxEvents),
                     @"eventCount": @(sAudioBusDiagnosticsEvents.count),
                     @"events": [sAudioBusDiagnosticsEvents copy]};
        }
    }

    if ([action isEqualToString:@"mediatorState"]) {
        return SpliceKitAudioBusMediatorState(params ?: @{});
    }

    return @{@"error": [NSString stringWithFormat:@"Unknown audio bus diagnostics action: %@", action]};
}
