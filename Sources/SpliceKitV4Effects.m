// Catalog and exact-instance effect lifecycle, without selection or pasteboard mutation.
#import "SpliceKitV4Parameters.h"
#import "SpliceKit.h"
#import "SpliceKitV4Core.h"
#import <objc/message.h>

static NSDictionary *SKV4PCatalog(NSDictionary *params) {
    id offset = params[@"offset"] ?: @0, limit = params[@"limit"] ?: @100;
    SKV4PRequire(SKV4PInteger(offset) && [offset longLongValue] >= 0 &&
                 SKV4PInteger(limit) && [limit longLongValue] >= 1 && [limit longLongValue] <= 500,
                 @"INVALID_ARGUMENT", @"offset must be nonnegative and limit must be 1..500");
    NSDictionary *types = @{@"effect.video.filter":@"filter", @"effect.video.title":@"title",
        @"effect.video.generator":@"generator", @"effect.audio.effect":@"audio", @"effect.video.transition":@"transition"};
    for (NSString *key in @[@"query", @"type", @"category"])
        SKV4PRequire(!params[key] || [params[key] isKindOfClass:NSString.class], @"INVALID_ARGUMENT", key);
    SKV4PRequire(!params[@"type"] || [types.allValues containsObject:params[@"type"]], @"INVALID_ARGUMENT", @"Unknown effect type");
    id registry = (id)NSClassFromString(@"FFEffect");
    SKV4PRequire(SKV4PHas(registry, @"userVisibleEffectIDs"), @"UNSUPPORTED_CAPABILITY", @"FFEffect registry unavailable");
    NSMutableArray *rows = [NSMutableArray array];
    for (NSString *effectID in SKV4PArray(SKV4PObject(registry, @"userVisibleEffectIDs"))) {
        if (![effectID isKindOfClass:NSString.class]) continue;
        NSString *nativeType = SKV4PObject1(registry, @"effectTypeForEffectID:", effectID);
        NSString *type = types[nativeType ?: @""] ?: @"unknown";
        NSString *name = SKV4PObject1(registry, @"displayNameForEffectID:", effectID) ?: effectID;
        NSString *category = SKV4PObject1(registry, @"categoryForEffectID:", effectID) ?: @"";
        if (params[@"type"] && ![type isEqual:params[@"type"]]) continue;
        if ([params[@"category"] length] && ![category isEqual:params[@"category"]]) continue;
        NSString *query = params[@"query"];
        if (query.length && [name rangeOfString:query options:NSCaseInsensitiveSearch].location == NSNotFound &&
            [category rangeOfString:query options:NSCaseInsensitiveSearch].location == NSNotFound &&
            [effectID rangeOfString:query options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
        id url = SKV4PObject1(registry, @"fileURLFromEffectID:", effectID);
        NSString *path = [url isKindOfClass:NSURL.class] && [url isFileURL] ? [url path] : nil;
        BOOL isDirectory = NO;
        BOOL payload = path && [NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDirectory] && !isDirectory;
        if (path && isDirectory) {
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Contents/Info.plist"]];
            NSString *relative = info[@"com.apple.motion.package.projectFilePath"];
            if ([relative isKindOfClass:NSString.class] && !relative.isAbsolutePath) {
                path = [path stringByAppendingPathComponent:relative];
                payload = [NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDirectory] && !isDirectory;
            }
        }
        // Only the FxPlug namespace identifies a package UUID. A Motion inner plugin UUID is not its template identity.
        NSString *uuid = [effectID hasPrefix:@"FxPlug:"] ? [effectID substringFromIndex:7] : nil;
        if (uuid && ![[NSUUID alloc] initWithUUIDString:uuid]) uuid = nil;
        [rows addObject:@{@"effectID":effectID, @"type":type, @"native_type":nativeType ?: NSNull.null,
            @"category":category, @"localized_name":name,
            @"stable_name":effectID, @"stable_name_source":@"effectID",
            @"template_path":path ?: NSNull.null, @"package_uuid":uuid ?: NSNull.null,
            @"payload_available":path ? @(payload) : NSNull.null}];
    }
    [rows sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [a[@"effectID"] compare:b[@"effectID"] options:NSLiteralSearch]; }];
    NSUInteger start = MIN([offset unsignedLongLongValue], rows.count);
    NSUInteger count = MIN([limit unsignedIntegerValue], rows.count - start);
    return @{@"effects":[rows subarrayWithRange:NSMakeRange(start, count)], @"total":@(rows.count),
        @"offset":offset, @"limit":limit, @"next_offset":start + count < rows.count ? @(start + count) : NSNull.null};
}

NSArray *SKV4PEffectInventory(SKV4PContext *context) {
    NSMutableArray *rows = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (id effect in SKV4PArray(SKV4PObject(context.stack, @"effects"))) {
        NSString *instance = SKV4PEffectIdentity(effect);
        SKV4PRequire(instance.length && ![seen containsObject:instance], @"AMBIGUOUS_IDENTITY", @"Effects require unique native persistentID (legacy fileUUID when absent) identities");
        [seen addObject:instance];
        NSString *effectID = SKV4PObject(effect, @"effectID");
        NSUInteger section = 0, index = 0;
        BOOL located = NO;
        if (SKV4PHas(context.stack, @"getSection:andIndexInSection:forEffect:"))
            located = ((BOOL (*)(id, SEL, NSUInteger *, NSUInteger *, id))objc_msgSend)(context.stack,
                NSSelectorFromString(@"getSection:andIndexInSection:forEffect:"), &section, &index, effect);
        [rows addObject:@{@"effect_instance_id":instance, @"effectID":effectID ?: NSNull.null,
            @"localized_name":SKV4PObject(effect, @"displayName") ?: effectID ?: @"",
            @"enabled":SKV4PHas(effect, @"enabled") ? @(SKV4PBool(effect, @"enabled")) : NSNull.null,
            @"section":located ? @(section) : NSNull.null, @"index_in_section":located ? @(index) : NSNull.null}];
    }
    return rows;
}

NSDictionary *SpliceKitV4_handleEffect(NSString *operation, NSDictionary *params) {
    BOOL mutation = ![operation isEqual:@"catalog"];
    return SKV4PRun(params, [@"v4.effect." stringByAppendingString:operation], mutation, ^NSDictionary *(SKV4PContext *c) {
        if (!mutation) return SKV4PCatalog(params);
        [c resolveTarget];
        NSArray *before = SKV4PEffectInventory(c);
        c.readback = @{@"effects":before};
        if ([operation isEqual:@"add"]) {
            SKV4PRequire(!params[@"target"][@"effect_instance_id"], @"INVALID_ARGUMENT", @"effect.add targets a clip");
            NSString *effectID = params[@"effect_id"];
            SKV4PRequire([effectID isKindOfClass:NSString.class] && effectID.length, @"INVALID_ARGUMENT", @"Full effect_id required");
            id registry = (id)NSClassFromString(@"FFEffect");
            NSString *type = SKV4PObject1(registry, @"effectTypeForEffectID:", effectID);
            SKV4PRequire([@[@"effect.video.filter", @"effect.audio.effect"] containsObject:type ?: @""],
                         @"UNSUPPORTED_CAPABILITY", @"Use clip insertion for titles/generators and transition workflow for transitions");
            SKV4PRequire(SKV4PHas(c.stack, @"addEffectWithID:"), @"UNSUPPORTED_CAPABILITY", @"Native effect insertion unavailable");
            [c beginMutation]; c.applied = NSNull.null;
            id effect = SKV4PObject1(c.stack, @"addEffectWithID:", effectID);
            c.applied = @YES;
            NSArray *after = SKV4PEffectInventory(c);
            NSString *instance = SKV4PEffectIdentity(effect);
            c.readback = @{@"target":@{@"clip_id":params[@"target"][@"clip_id"], @"effect_instance_id":instance ?: NSNull.null},
                           @"effects":after, @"before":before};
            SKV4PRequire(instance && after.count == before.count + 1 &&
                ![[before valueForKey:@"effect_instance_id"] containsObject:instance] &&
                [[after valueForKey:@"effect_instance_id"] containsObject:instance] && [SKV4PObject(effect, @"effectID") isEqual:effectID],
                @"READBACK_MISMATCH", @"Insertion did not produce one new exact native instance");
        } else {
            SKV4PRequire(c.effect != nil, @"INVALID_ARGUMENT", @"Exact effect_instance_id required");
            // Intrinsics are edited through parameters, never removed/reordered as ordinary filters.
            SKV4PRequire(![SKV4PArray(SKV4PObject(c.stack, @"intrinsicEffects")) containsObject:c.effect],
                         @"UNSUPPORTED_CAPABILITY", @"Intrinsic effects use the parameter tree");
            NSString *instance = params[@"target"][@"effect_instance_id"];
            if ([operation isEqual:@"remove"]) {
                SKV4PRequire(SKV4PHas(c.stack, @"removeEffects:"), @"UNSUPPORTED_CAPABILITY", @"Native exact removal unavailable");
                [c beginMutation]; c.applied = NSNull.null;
                ((void (*)(id, SEL, id))objc_msgSend)(c.stack, NSSelectorFromString(@"removeEffects:"), @[c.effect]);
                c.applied = @YES;
                NSArray *after = SKV4PEffectInventory(c);
                c.readback = @{@"target":params[@"target"], @"before":before, @"effects":after};
                NSMutableArray *expected = [[before valueForKey:@"effect_instance_id"] mutableCopy]; [expected removeObject:instance];
                SKV4PRequire([expected isEqual:[after valueForKey:@"effect_instance_id"]], @"READBACK_MISMATCH", @"Exact removal changed unexpected instances");
            } else if ([operation isEqual:@"enable"]) {
                id enabled = params[@"enabled"];
                SKV4PRequire([enabled isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)enabled) == CFBooleanGetTypeID(), @"INVALID_ARGUMENT", @"enabled must be boolean");
                SKV4PRequire(SKV4PHas(c.effect, @"setEnabled:") && SKV4PHas(c.effect, @"enabled"), @"UNSUPPORTED_CAPABILITY", @"Native bypass unavailable");
                BOOL previous = SKV4PBool(c.effect, @"enabled");
                [c beginMutation]; c.applied = NSNull.null;
                SKV4PRequire(SpliceKitV4RegisterUndo(c.effect, ^(id effect) {
                    ((void (*)(id,SEL,BOOL))objc_msgSend)(effect,NSSelectorFromString(@"setEnabled:"),previous);
                }), @"UNDO_UNAVAILABLE", @"No current operation-owned undo group");
                ((void (*)(id, SEL, BOOL))objc_msgSend)(c.effect, NSSelectorFromString(@"setEnabled:"), [enabled boolValue]); c.applied = @YES;
                c.readback = @{@"target":params[@"target"], @"enabled":@(SKV4PBool(c.effect, @"enabled")), @"before":before, @"effects":SKV4PEffectInventory(c)};
                SKV4PRequire([c.readback[@"enabled"] isEqual:enabled], @"READBACK_MISMATCH", @"Native enable state differs");
            } else if ([operation isEqual:@"move"]) {
                SKV4PRequire(params[@"before_instance_id"] != nil, @"INVALID_ARGUMENT", @"before_instance_id required (null means section end)");
                SKV4PRequire(SKV4PHas(c.stack, @"getSection:andIndexInSection:forEffect:") && SKV4PHas(c.stack, @"moveEffects:toIndex:inSection:"), @"UNSUPPORTED_CAPABILITY", @"Section-aware native move unavailable");
                NSDictionary *source = [before filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"effect_instance_id == %@", instance]].firstObject;
                SKV4PRequire([source[@"section"] isKindOfClass:NSNumber.class], @"UNSUPPORTED_CAPABILITY", @"Native section missing");
                NSNumber *section = source[@"section"];
                NSArray *sectionRows = [before filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"section == %@", section]];
                NSMutableArray *expected = [[sectionRows valueForKey:@"effect_instance_id"] mutableCopy]; [expected removeObject:instance];
                id dest = params[@"before_instance_id"];
                SKV4PRequire(dest == NSNull.null || ([dest isKindOfClass:NSString.class] && [expected containsObject:dest]), @"INVALID_ARGUMENT", @"Move destination must be a different instance in the same section");
                NSUInteger finalIndex = dest == NSNull.null ? expected.count : [expected indexOfObject:dest];
                [expected insertObject:instance atIndex:finalIndex];
                // FCP 12.4 live fixture verified this pre-removal insertion index, exact
                // instance order and owned XML restoration; never retry automatically.
                NSUInteger nativeIndex = finalIndex + ([source[@"index_in_section"] unsignedIntegerValue] < finalIndex ? 1 : 0);
                [c beginMutation]; c.applied = NSNull.null;
                ((void (*)(id, SEL, id, NSUInteger, NSUInteger))objc_msgSend)(c.stack, NSSelectorFromString(@"moveEffects:toIndex:inSection:"), @[c.effect], nativeIndex, section.unsignedIntegerValue); c.applied = @YES;
                NSArray *after = SKV4PEffectInventory(c);
                c.readback = @{@"target":params[@"target"], @"before":before, @"effects":after};
                NSArray *actual = [[after filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"section == %@", section]] valueForKey:@"effect_instance_id"];
                SKV4PRequire([expected isEqual:actual], @"READBACK_MISMATCH", @"Native instance order differs from requested destination");
            } else SKV4PRequire(NO, @"INVALID_ARGUMENT", @"Unknown effect operation");
        }
        NSDictionary *expectedReadback = c.readback;
        c.afterCommit = ^NSDictionary *(SKV4PContext *context) {
            NSArray *inventory = SKV4PEffectInventory(context);
            NSMutableDictionary *final = [expectedReadback mutableCopy]; final[@"effects"] = inventory;
            context.readback = final;
            SKV4PRequire([expectedReadback[@"effects"] isEqual:inventory],@"READBACK_MISMATCH",@"Native group close changed the instance inventory");
            return final;
        };
        return c.readback;
    });
}
