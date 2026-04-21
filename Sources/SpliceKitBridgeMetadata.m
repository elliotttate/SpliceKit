//
//  SpliceKitBridgeMetadata.m
//  Self-describing RPC surface + lightweight liveness probe.
//
//  Registers three endpoints through the plugin registry:
//    bridge.describe     — returns metadata for every known RPC (built-in + plugin)
//    bridge.alive        — cheap probe that doesn't touch the main thread
//    bridge.safetyTags   — returns the set of safety classifications used
//
//  Built-in method metadata is a static table seeded below. Methods registered
//  via SpliceKit_registerPluginMethod already carry their own metadata dict
//  (see SpliceKitServer.m — sPluginMethodMeta) and are merged into the output.
//

#import <Foundation/Foundation.h>
#import <unistd.h>
#import "SpliceKit.h"

extern NSDictionary *SpliceKit_getPluginMetadataSnapshot(void);  // defined in SpliceKitServer.m

// Safety classifications:
//   safe              — read-only, no side effects on project/library/UI
//   state_dependent   — modifies state, requires current selection/project/timeline
//   modal             — may open a dialog or block the UI
//   destructive       — writes to library/project/clips
//   system            — touches runtime, handles, debug internals
//
// When in doubt, use state_dependent.

static NSDictionary<NSString *, NSDictionary *> *sBuiltinMetadata = nil;

static NSDictionary *meta(NSString *safety, NSString *summary) {
    return @{@"safety": safety, @"summary": summary, @"source": @"builtin"};
}

static void SpliceKit_initBuiltinMetadata(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sBuiltinMetadata = @{
            // system.*
            @"system.version": meta(@"safe", @"SpliceKit + FCP version info."),
            @"system.getClasses": meta(@"safe", @"Enumerate ObjC classes in the process."),
            @"system.getMethods": meta(@"safe", @"List methods on a class."),
            @"system.callMethod": meta(@"system", @"Invoke an ObjC selector — can crash on bad selectors."),
            @"system.callMethodWithArgs": meta(@"system", @"Invoke an ObjC selector with typed args."),
            @"system.getProperties": meta(@"safe", @"List properties on a class."),
            @"system.getProtocols": meta(@"safe", @"List protocol conformances."),
            @"system.getSuperchain": meta(@"safe", @"Walk the inheritance chain."),
            @"system.getIvars": meta(@"safe", @"List ivars with byte offsets."),
            @"system.swizzle": meta(@"system", @"Swap method implementations."),

            // object.*
            @"object.get": meta(@"system", @"Resolve an object handle."),
            @"object.release": meta(@"system", @"Release an object handle."),
            @"object.list": meta(@"safe", @"List active object handles."),
            @"object.getProperty": meta(@"safe", @"Read a property via KVC."),
            @"object.setProperty": meta(@"destructive", @"Write a property via KVC."),

            // timeline.*
            @"timeline.action": meta(@"state_dependent", @"Run a timeline action via responder chain. Needs a loaded project."),
            @"timeline.directAction": meta(@"state_dependent", @"Call action* selector directly on timeline module."),
            @"timeline.getState": meta(@"safe", @"Read basic timeline state (name, duration)."),
            @"timeline.getDetailedState": meta(@"safe", @"Snapshot clips, handles, selection."),
            @"timeline.setRange": meta(@"state_dependent", @"Set in/out range selection."),
            @"timeline.addMarkers": meta(@"destructive", @"Batch-add markers at times."),
            @"timeline.bladeAtTimes": meta(@"destructive", @"Batch-blade at multiple times."),
            @"timeline.trimClipsToBeats": meta(@"destructive", @"Trim clips to a beat grid."),
            @"timeline.assembleRandomClipsToBeats": meta(@"destructive", @"Build beat-synced cut from browser pool."),
            @"timeline.batchActions": meta(@"destructive", @"Run a sequence of timeline+playback actions."),
            @"timeline.batchExport": meta(@"destructive", @"Export each clip via Share."),
            @"timeline.beginEdit": meta(@"state_dependent", @"Open an FFEditActionMgr group for atomic edits."),
            @"timeline.endEdit": meta(@"state_dependent", @"Close the current edit group."),

            // spine.*
            @"spine.getItems": meta(@"safe", @"Read spine-level items from primary storyline."),
            @"spine.reorder": meta(@"destructive", @"Move items within the spine."),
            @"spine.removeItemAtIndex": meta(@"destructive", @"Delete a spine item by index."),
            @"spine.insertItem": meta(@"destructive", @"Insert a spine item at position."),

            // playback.*
            @"playback.action": meta(@"state_dependent", @"Play/pause/step/shuttle."),
            @"playback.seekToTime": meta(@"state_dependent", @"Jump playhead to time (seconds)."),
            @"playback.getPosition": meta(@"safe", @"Read playhead position + playing state."),
            @"playback.setRate": meta(@"state_dependent", @"Set playback rate (negative for reverse)."),
            @"playback.shuttle": meta(@"state_dependent", @"Smooth shuttle at variable speed."),

            // fcpxml.*
            @"fcpxml.import": meta(@"destructive", @"Import FCPXML (new project or into current)."),
            @"fcpxml.pasteImport": meta(@"destructive", @"Paste FCPXML from clipboard."),
            @"otio.toFCPXML": meta(@"safe", @"Convert OTIO to FCPXML in memory."),

            // menu.*
            @"menu.execute": meta(@"modal", @"Execute a menu item by path. May open dialogs."),
            @"menu.list": meta(@"safe", @"List menu items at a path."),

            // effects.* / transitions.*
            @"effects.list": meta(@"safe", @"List all effects on current clip."),
            @"effects.getClipEffects": meta(@"safe", @"Effects on selected clip with handles."),
            @"effects.listAvailable": meta(@"safe", @"Browse library of installed effects."),
            @"effects.apply": meta(@"destructive", @"Apply an effect to the selected clip."),

            // inspector.*
            @"inspector.get": meta(@"safe", @"Read inspector properties of selected clip."),
            @"inspector.set": meta(@"destructive", @"Write an inspector property."),
            @"inspector.getTitle": meta(@"safe", @"Read text/font from selected title."),

            // view.*
            @"view.toggle": meta(@"state_dependent", @"Show/hide a panel (inspector, scopes, etc.)."),
            @"view.workspace": meta(@"state_dependent", @"Switch workspace layout."),

            // debug.*
            @"debug.traceMethod": meta(@"system", @"Install a method trace."),
            @"debug.watch": meta(@"system", @"Watch a keypath for changes."),
            @"debug.crashHandler": meta(@"system", @"Install/query crash handler."),
            @"debug.threads": meta(@"safe", @"Inspect process threads."),
            @"debug.eval": meta(@"system", @"Evaluate an ObjC keypath chain."),
            @"debug.loadPlugin": meta(@"system", @"Hot-load a dylib/bundle into FCP."),
            @"debug.observeNotification": meta(@"system", @"Subscribe to NSNotification events."),
            @"debug.breakpoint": meta(@"system", @"Install a method breakpoint (pauses FCP)."),

            // captions.*
            @"captions.open": meta(@"state_dependent", @"Open caption panel."),
            @"captions.close": meta(@"state_dependent", @"Close caption panel."),
            @"captions.getState": meta(@"safe", @"Read caption pipeline state."),
            @"captions.getStyles": meta(@"safe", @"List caption style presets."),
            @"captions.setStyle": meta(@"state_dependent", @"Apply a caption style."),
            @"captions.generate": meta(@"destructive", @"Generate and paste captions onto timeline."),
            @"captions.verify": meta(@"safe", @"Inspect titles to verify caption text."),
            @"captions.exportSRT": meta(@"safe", @"Write SRT file."),
            @"captions.exportTXT": meta(@"safe", @"Write plain text file."),

            // transcript.*
            @"transcript.open": meta(@"destructive", @"Transcribe timeline or file (long-running)."),
            @"transcript.close": meta(@"state_dependent", @"Close transcript panel."),
            @"transcript.getState": meta(@"safe", @"Read transcript words/silences/speakers."),
            @"transcript.deleteWords": meta(@"destructive", @"Delete timeline segments by word range."),
            @"transcript.moveWords": meta(@"destructive", @"Reorder timeline segments."),
            @"transcript.search": meta(@"safe", @"Search transcript text."),
            @"transcript.deleteSilences": meta(@"destructive", @"Ripple-delete pauses."),

            // scene.*
            @"scene.detect": meta(@"safe", @"Detect scene changes in timeline."),
        };
    });
}

NSDictionary *SpliceKit_builtinMetadataForMethod(NSString *method) {
    SpliceKit_initBuiltinMetadata();
    return sBuiltinMetadata[method];
}

static NSDictionary *SpliceKit_handleBridgeDescribe(NSDictionary *params) {
    SpliceKit_initBuiltinMetadata();

    NSString *wanted = params[@"method"];
    NSString *safetyFilter = params[@"safety"];

    // Merge built-in + plugin-registered metadata
    NSMutableDictionary *merged = [NSMutableDictionary dictionary];
    for (NSString *name in sBuiltinMetadata) {
        merged[name] = sBuiltinMetadata[name];
    }
    NSDictionary *pluginSnapshot = SpliceKit_getPluginMetadataSnapshot();
    for (NSString *name in pluginSnapshot) {
        NSMutableDictionary *entry = [pluginSnapshot[name] mutableCopy] ?: [NSMutableDictionary dictionary];
        if (!entry[@"source"]) entry[@"source"] = @"plugin";
        merged[name] = entry;
    }

    if (wanted) {
        NSDictionary *entry = merged[wanted];
        if (!entry) return @{@"error": [NSString stringWithFormat:@"No metadata for %@", wanted]};
        NSMutableDictionary *out = [entry mutableCopy];
        out[@"name"] = wanted;
        return out;
    }

    NSMutableArray *methods = [NSMutableArray arrayWithCapacity:merged.count];
    NSUInteger classified = 0;
    for (NSString *name in merged) {
        NSDictionary *entry = merged[name];
        NSString *safety = entry[@"safety"] ?: @"unclassified";
        if (safetyFilter && ![safety isEqualToString:safetyFilter]) continue;
        NSMutableDictionary *out = [entry mutableCopy];
        out[@"name"] = name;
        [methods addObject:out];
        if (![safety isEqualToString:@"unclassified"]) classified += 1;
    }
    [methods sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] compare:b[@"name"]];
    }];
    return @{
        @"methods": methods,
        @"count": @(methods.count),
        @"classified": @(classified),
        @"safety_tags": @[@"safe", @"state_dependent", @"modal", @"destructive", @"system", @"unclassified"],
    };
}

static NSDictionary *SpliceKit_handleBridgeAlive(NSDictionary *params) {
    // Deliberately doesn't touch the main thread — purely process-local.
    return @{
        @"alive": @YES,
        @"version": @SPLICEKIT_VERSION,
        @"pid": @(getpid()),
        @"timestamp": @([[NSDate date] timeIntervalSince1970]),
    };
}

static NSDictionary *SpliceKit_handleBridgeSafetyTags(NSDictionary *params) {
    return @{
        @"tags": @{
            @"safe": @"Read-only, no side effects.",
            @"state_dependent": @"Modifies state; needs project/selection/timeline.",
            @"modal": @"May open a dialog or block the UI.",
            @"destructive": @"Writes to library/project/clips.",
            @"system": @"Runtime/handles/debug internals.",
            @"unclassified": @"No classification yet — treat as potentially destructive.",
        }
    };
}

void SpliceKit_installBridgeMetadata(void) {
    SpliceKit_initBuiltinMetadata();

    SpliceKit_registerPluginMethod(@"bridge.describe",
        ^NSDictionary *(NSDictionary *params) { return SpliceKit_handleBridgeDescribe(params); },
        @{@"safety": @"safe",
          @"summary": @"Self-describing metadata for every known RPC method.",
          @"source": @"builtin"});

    SpliceKit_registerPluginMethod(@"bridge.alive",
        ^NSDictionary *(NSDictionary *params) { return SpliceKit_handleBridgeAlive(params); },
        @{@"safety": @"safe",
          @"summary": @"Cheap liveness probe — does not touch main thread.",
          @"source": @"builtin"});

    SpliceKit_registerPluginMethod(@"bridge.safetyTags",
        ^NSDictionary *(NSDictionary *params) { return SpliceKit_handleBridgeSafetyTags(params); },
        @{@"safety": @"safe",
          @"summary": @"Enumerate safety classifications and their meanings.",
          @"source": @"builtin"});

    SpliceKit_log(@"[BridgeMetadata] Registered bridge.describe / bridge.alive / bridge.safetyTags (%lu built-in methods catalogued)",
                  (unsigned long)sBuiltinMetadata.count);
}
