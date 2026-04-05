# SpliceKit Debug Tools Guide

SpliceKit includes a full in-process debugging toolkit that provides debugger-level
capabilities without requiring Xcode or lldb to be attached. These tools run inside
FCP's process via the injected dylib, giving direct access to runtime state, method
tracing, crash handling, and live code injection.

All debug tools are accessed via JSON-RPC on `127.0.0.1:9876`.

## Quick Reference

| Endpoint | Purpose |
|----------|---------|
| `debug.breakpoint` | True breakpoints: pause execution, inspect state, continue/step |
| `debug.traceMethod` | Swizzle methods to log calls, args, and call stacks |
| `debug.watch` | KVO-based property change observation |
| `debug.crashHandler` | Catch uncaught exceptions and signals |
| `debug.threads` | Inspect all threads with CPU usage and stack traces |
| `debug.eval` | Evaluate ObjC property chains in FCP's process |
| `debug.loadPlugin` | Hot-load dylibs/bundles into FCP without restart |
| `debug.observeNotification` | Subscribe to NSNotificationCenter events |
| `debug.getConfig` | Read debug flag state (TLK, CFPreferences, log) |
| `debug.setConfig` | Set individual debug flags |
| `debug.enablePreset` | Apply preset debug configurations |
| `debug.resetConfig` | Reset debug flags to defaults |
| `debug.startFramerateMonitor` | Monitor rendering FPS |
| `debug.stopFramerateMonitor` | Stop FPS monitor |
| `debug.dumpRuntimeMetadata` | Dump ObjC class/method/ivar data |
| `debug.listLoadedImages` | List all loaded dylibs/frameworks |
| `debug.getImageSections` | Read Mach-O section data |
| `debug.getImageSymbols` | Read symbol tables |
| `debug.getNotificationNames` | List all notification name constants |

## Breakpoints (`debug.breakpoint`)

True breakpoints that pause FCP execution at any ObjC method, let you inspect the
full object state while paused, then continue or step. FCP's UI freezes while
paused — exactly like Xcode's debugger, but controlled entirely through MCP.

The JSON-RPC server runs on a separate thread, so it keeps accepting commands
while FCP is paused. This is what makes inspect/continue/step possible.

### Set a breakpoint

```python
# Basic breakpoint
debug.breakpoint(action="add", className="FFAnchoredTimelineModule", selector="blade:")

# Conditional breakpoint — only fires when keyPath evaluates to truthy
debug.breakpoint(action="add", className="FFAnchoredTimelineModule",
                 selector="blade:", condition="sequence.hasContainedItems")

# Hit count — only fires on the Nth call
debug.breakpoint(action="add", className="FFAnchoredTimelineModule",
                 selector="blade:", hitCount=3)

# One-shot — fires once then auto-removes
debug.breakpoint(action="add", className="FFAnchoredTimelineModule",
                 selector="blade:", oneShot=True)
```

### When a breakpoint fires

1. The calling thread is **paused** (blocks on a semaphore)
2. A `breakpoint.hit` event is broadcast to MCP clients:
```json
{
  "jsonrpc": "2.0",
  "method": "event",
  "params": {
    "type": "breakpoint.hit",
    "data": {
      "breakpoint": "FFAnchoredTimelineModule.blade:",
      "selector": "blade:",
      "selfClass": "FFAnchoredTimelineModule",
      "self": "<FFAnchoredTimelineModule: 0x...>",
      "selfHandle": "obj_42",
      "firstArg": "<sender description>",
      "firstArgHandle": "obj_43",
      "callStack": ["0 SpliceKit ...", "1 Flexo ...", ...],
      "timestamp": 1743811200.123,
      "threadName": "main",
      "isMainThread": true
    }
  }
}
```

### Inspect state while paused

```python
# Get the full paused state
debug.breakpoint(action="inspect")
# Returns: {paused: true, breakpoint: "...", selfHandle: "obj_42", callStack: [...], ...}

# Inspect properties on the paused self object
debug.breakpoint(action="inspectSelf", keyPath="sequence.displayName")
# Returns: {keyPath: "sequence.displayName", value: "My Timeline", class: "__NSCFString"}

debug.breakpoint(action="inspectSelf", keyPath="sequence.primaryObject.containedItems.count")
# Returns: {keyPath: "...", value: "12", class: "__NSCFNumber"}

# Store a property value as a handle for deeper inspection
debug.breakpoint(action="inspectSelf", keyPath="sequence", storeResult=True)
# Returns: {keyPath: "sequence", value: "...", class: "FFAnchoredSequence", handle: "obj_44"}

# Use debug.eval with the stored handle
debug.eval(target="obj_44", chain=["primaryObject", "containedItems", "count"])
```

### Resume execution

```python
# Continue — resume normal execution
debug.breakpoint(action="continue")

# Step — resume but auto-break on the next call to any breakpointed method
# on the same class
debug.breakpoint(action="step")
# Returns: {message: "Stepping — will break on next call to FFAnchoredTimelineModule"}
```

### Manage breakpoints

```python
debug.breakpoint(action="list")       # list all breakpoints + paused state
debug.breakpoint(action="disable", className="...", selector="...")  # keep but don't fire
debug.breakpoint(action="enable", className="...", selector="...")   # re-enable
debug.breakpoint(action="remove", className="...", selector="...")   # remove + unswizzle
debug.breakpoint(action="removeAll")  # remove all + resume if paused
```

### Breakpoint modes

| Args | Mode | Behavior |
|------|------|----------|
| 0-1 object args (after self+_cmd) | `swizzle` | Full breakpoint — pauses, inspects, forwards to original |
| 2+ object args | `trace_only` | Registered but not swizzled (can't safely forward args). Use `debug.traceMethod` instead |

### Workflow: Reverse-engineering how FCP implements blade

```python
# 1. Set breakpoint
debug.breakpoint(action="add", className="FFAnchoredTimelineModule",
                 selector="blade:", oneShot=True)

# 2. Press B in FCP to blade at playhead
# → FCP freezes, breakpoint.hit event fires

# 3. Inspect the timeline module's state
debug.breakpoint(action="inspectSelf", keyPath="sequence.displayName")
debug.breakpoint(action="inspectSelf", keyPath="selectedItems.count")
debug.breakpoint(action="inspectSelf", keyPath="currentPlayheadTime")

# 4. Look at the call stack to see how we got here
debug.breakpoint(action="inspect")  # callStack field shows the full chain

# 5. Continue execution
debug.breakpoint(action="continue")
```

### Workflow: Debugging the freeze-extend crash

```python
# 1. Set breakpoint on the method that crashes
debug.breakpoint(action="add", className="FFAnchoredTimelineModule",
                 selector="retimeHold:")

# 2. Trigger the operation
timeline_action("retimeHold")
# → Breakpoint fires BEFORE the crash

# 3. Inspect state to understand what's wrong
debug.breakpoint(action="inspectSelf", keyPath="selectedItems")
debug.breakpoint(action="inspectSelf", keyPath="sequence.primaryObject")

# 4. Continue to let it crash (crash handler will catch the details)
debug.crashHandler(action="install")
debug.breakpoint(action="continue")
# → Crash handler captures the exception + stack trace
debug.crashHandler(action="getLog")
```

### Safety notes

- Breakpoints on the JSON-RPC server thread are automatically skipped (prevents deadlock)
- `removeAll` auto-resumes if execution is paused (prevents stuck threads)
- One-shot breakpoints auto-unswizzle after firing
- Disabled breakpoints still intercept but call the original without pausing

## Method Tracing (`debug.traceMethod`)

Swizzle any ObjC method to log every call. Traces are stored in a circular buffer
(500 entries) and broadcast to connected MCP clients in real-time via JSON-RPC
notifications.

### Add a trace

```python
# Trace a simple method (0-1 args) - uses swizzle mode
debug.traceMethod(
    action="add",
    className="FFAnchoredTimelineModule",
    selector="bladeAtPlayhead",
    logStack=True    # include call stack in trace entries
)

# Trace a multi-arg method - uses notification_only mode
# (logs registration but can't intercept args directly via swizzle)
debug.traceMethod(
    action="add",
    className="FFAnchoredTimelineModule",
    selector="actionRetimeSetRatePreset:rate:ripple:allowVariableSpeedRetiming:objectsAndNewRanges:error:",
    logStack=True,
    logArgs=True
)
```

**Swizzle mode** (0-1 object args): Replaces the method implementation with a
trampoline that logs the call and forwards to the original. Full interception.

**Notification-only mode** (2+ args): Registers the trace but can't safely swizzle
due to varargs limitations. Use `call_method` with `store_result` for full arg
inspection of multi-arg methods, or use `debug.eval` to inspect state before/after.

### Read the trace log

```python
debug.traceMethod(action="getLog", limit=50)
# Returns: {
#   "log": [
#     {
#       "class": "FFAnchoredTimelineModule",
#       "selector": "bladeAtPlayhead",
#       "timestamp": 1743811200.123,
#       "selfClass": "FFAnchoredTimelineModule",
#       "self": "<FFAnchoredTimelineModule: 0x...>",
#       "callStack": ["0 SpliceKit ...", "1 Flexo ...", ...]
#     }
#   ],
#   "count": 1,
#   "total": 1
# }
```

Trace entries are also broadcast as events to connected clients:
```json
{"jsonrpc":"2.0","method":"event","params":{"type":"trace","data":{...}}}
```

### Remove traces

```python
debug.traceMethod(action="remove", className="FFAnchoredTimelineModule", selector="bladeAtPlayhead")
debug.traceMethod(action="removeAll")   # remove all active traces
debug.traceMethod(action="clearLog")    # clear the trace log buffer
debug.traceMethod(action="list")        # list active traces
```

### Workflow: Reverse-engineering a feature

1. Trace the method you think FCP calls:
   ```python
   debug.traceMethod(action="add", className="FFAnchoredTimelineModule",
                     selector="blade:", logStack=True)
   ```
2. Perform the action in FCP's UI (e.g., press B to blade)
3. Read the trace log:
   ```python
   debug.traceMethod(action="getLog", limit=5)
   ```
4. The call stack shows you the full chain: menu item -> responder chain -> timeline module -> blade method
5. Clean up:
   ```python
   debug.traceMethod(action="removeAll")
   ```

## Property Watching (`debug.watch`)

Observe property changes on any object via KVO (Key-Value Observing). When a
watched property changes, the old and new values are broadcast to MCP clients.

### Watch a property

```python
# Watch by object handle (from call_method with store_result)
debug.watch(action="add", handle="obj_1", keyPath="displayName")

# Watch by class (resolves singleton automatically)
debug.watch(action="add", className="NSApplication", keyPath="mainWindow")

# Watch a timeline property
debug.watch(action="add", className="FFAnchoredTimelineModule", keyPath="sequence")
```

### Change events

When a watched property changes, clients receive:
```json
{
  "jsonrpc": "2.0",
  "method": "event",
  "params": {
    "type": "watch",
    "watchKey": "PEApplication.mainWindow",
    "keyPath": "mainWindow",
    "objectClass": "PEApplication",
    "oldValue": "<NSWindow: 0x...>",
    "newValue": "<NSWindow: 0x...>",
    "timestamp": 1743811200.456
  }
}
```

### Manage watches

```python
debug.watch(action="list")                          # list active watches
debug.watch(action="remove", watchKey="obj_1.displayName")  # remove specific
debug.watch(action="removeAll")                     # remove all watches
```

### Common watch targets

| Object | Property | When it changes |
|--------|----------|-----------------|
| NSApplication | mainWindow | Window focus changes |
| FFAnchoredTimelineModule | sequence | Project/timeline switches |
| FFAnchoredSequence | primaryObject | Timeline structure changes |
| FFPlayerModule | currentTime | Playhead moves |

## Crash Handler (`debug.crashHandler`)

Catches uncaught NSExceptions and Unix signals (SIGABRT, SIGSEGV, SIGBUS, SIGFPE,
SIGILL) inside FCP's process. Captures full stack traces and broadcasts crash info
to connected MCP clients before the process terminates.

### Install

```python
debug.crashHandler(action="install")
# Returns: {"status": "ok", "message": "Crash handler installed (exceptions + signals)"}
```

Install once at the start of a session. Idempotent -- calling again is safe.

### When a crash occurs

**Exception crashes** are caught by `NSSetUncaughtExceptionHandler`. The handler:
1. Captures exception name, reason, call stack symbols, and userInfo
2. Logs to `~/Library/Logs/SpliceKit/splicekit.log`
3. Broadcasts to connected MCP clients
4. Stores in crash log buffer

**Signal crashes** (SIGSEGV, SIGABRT, etc.) are caught by `signal()` handlers. The handler:
1. Captures signal name and call stack
2. Logs to SpliceKit log
3. Re-raises the signal so the default handler runs (or Xcode debugger catches it)

### Read crash log

```python
debug.crashHandler(action="getLog")
# Returns: {
#   "crashes": [
#     {
#       "type": "exception",
#       "name": "NSInvalidArgumentException",
#       "reason": "-[FFAnchoredMediaComponent retimeHold:]: unrecognized selector",
#       "callStack": ["0 CoreFoundation ...", ...],
#       "timestamp": 1743811200.789
#     }
#   ],
#   "count": 1
# }

debug.crashHandler(action="status")    # check if installed + crash count
debug.crashHandler(action="clearLog")  # clear the crash log
```

### Workflow: Debugging the freeze-extend crash

1. Install crash handler:
   ```python
   debug.crashHandler(action="install")
   ```
2. Attempt the operation that crashes:
   ```python
   timeline.directAction(action="retimeHoldPreset")
   ```
3. If FCP crashes, check the log (on next launch):
   ```python
   debug.crashHandler(action="getLog")
   ```
4. The crash entry shows the exact exception, reason, and call stack

## Thread Inspection (`debug.threads`)

Lists all threads in FCP's process with CPU usage, run state, and optional stack
traces. Uses Mach kernel APIs for accurate thread counts and performance data.

### Basic inspection

```python
debug.threads()
# Returns: {
#   "currentThread": {"name": "(unnamed)", "isMain": false, "qualityOfService": 25},
#   "mainThread": {"name": "main", "isMain": true},
#   "totalThreadCount": 45,
#   "operationQueues": [
#     {"name": "mainQueue", "operationCount": 0, "suspended": false},
#     {"name": "FFBackgroundTaskQueue", "description": "..."}
#   ]
# }
```

### Detailed inspection (with CPU and stack traces)

```python
debug.threads(detailed=True)
# Adds per-thread info:
# "threads": [
#   {
#     "index": 0,
#     "cpuUsage": 12.5,           // percentage (0-100)
#     "userTime": 45.123,          // seconds
#     "systemTime": 3.456,         // seconds
#     "runState": 1,               // 1=running, 2=stopped, 3=waiting
#     "suspended": false
#   },
#   ...
# ]
# Also adds callStack to currentThread and mainThread
```

### Run states

| Value | Meaning |
|-------|---------|
| 1 | Running |
| 2 | Stopped |
| 3 | Waiting |
| 4 | Uninterruptible |
| 5 | Halted |

## Expression Evaluation (`debug.eval`)

Evaluate ObjC property chains and method calls inside FCP's process. Supports
dot-separated expressions and array-based chains with handle storage.

### Dot expression syntax

```python
# Simple property chain
debug.eval(expression="NSApp.delegate")
# Returns: {"result": "<PEAppController: 0x...>", "class": "PEAppController"}

# Deep chain
debug.eval(expression="NSApp.delegate._targetLibrary.displayName")
# Returns: {"result": "My Library", "class": "__NSCFString"}

# Store result as handle for further use
debug.eval(expression="NSApp.delegate._targetLibrary", storeResult=True)
# Returns: {"result": "...", "class": "FFLibrary", "handle": "obj_3"}
```

### Chain syntax (with steps)

```python
debug.eval(chain=["delegate", "_targetLibrary", "displayName"])
# Returns: {
#   "steps": [
#     {"step": "delegate", "class": "PEAppController", "value": "..."},
#     {"step": "_targetLibrary", "class": "FFLibrary", "value": "..."},
#     {"step": "displayName", "class": "__NSCFString", "value": "My Library"}
#   ],
#   "result": "My Library",
#   "resultClass": "__NSCFString"
# }

# Start from a stored handle
debug.eval(target="obj_3", chain=["displayName"])
```

### Starting objects

| Expression prefix | Resolves to |
|-------------------|-------------|
| `NSApp` | `[NSApplication sharedApplication]` |
| `obj_XXX` | Stored handle |
| `ClassName` | Singleton via sharedInstance/shared/defaultManager, or class itself |

### Property resolution

Each step in the chain tries:
1. `respondsToSelector:` -> `objc_msgSend` (method call)
2. `valueForKey:` (KVC fallback)

### Common useful expressions

```python
debug.eval(expression="NSApp.delegate._targetLibrary.displayName")
debug.eval(expression="NSApp.delegate._targetLibrary._deepLoadedSequences")
debug.eval(expression="NSApp.mainWindow.title")
debug.eval(expression="NSApp.delegate.activeEditorContainer")
```

## Hot Plugin Loading (`debug.loadPlugin`)

Dynamically load compiled code into FCP's running process without restarting.
Supports both `.dylib` files (via `dlopen`) and `.bundle`/`.framework` packages
(via `NSBundle`).

### Load a dylib

```python
debug.loadPlugin(action="load", path="/path/to/patch.dylib")
# Returns: {"status": "ok", "path": "...", "type": "dylib"}
```

The dylib's `__attribute__((constructor))` function runs immediately on load.
Use this for hot-patching: compile a dylib that swizzles methods or adds new
functionality, then load it without restarting FCP.

### Load a bundle

```python
debug.loadPlugin(action="load", path="/path/to/MyPlugin.bundle")
# Returns: {"status": "ok", "path": "...", "type": "bundle", "principalClass": "MyPlugin"}
```

### Unload

```python
debug.loadPlugin(action="unload", path="/path/to/patch.dylib")
# Returns: {"status": "ok", "path": "...", "type": "dylib"}
```

**Note**: ObjC classes registered by a bundle can't be fully unloaded from the
runtime. Dylibs can be unloaded via `dlclose` if no symbols are still referenced.

### List loaded plugins

```python
debug.loadPlugin(action="list")
# Returns: {"plugins": ["/path/to/patch.dylib"], "count": 1}
```

### Hot-patch workflow

1. Write a patch file:
   ```objc
   // patch.m
   #import <Foundation/Foundation.h>
   #import <objc/runtime.h>
   
   __attribute__((constructor))
   void applyPatch(void) {
       // Swizzle or replace method implementations
       NSLog(@"[Patch] Applied!");
   }
   ```
2. Compile:
   ```bash
   clang -dynamiclib -framework Foundation -undefined dynamic_lookup \
         -o /tmp/patch.dylib patch.m
   ```
3. Load into running FCP:
   ```python
   debug.loadPlugin(action="load", path="/tmp/patch.dylib")
   ```
4. Test the change
5. Unload when done:
   ```python
   debug.loadPlugin(action="unload", path="/tmp/patch.dylib")
   ```

## Notification Observation (`debug.observeNotification`)

Subscribe to NSNotificationCenter events inside FCP's process. Notifications are
broadcast to connected MCP clients in real-time. This is how you discover what
events FCP posts internally when you perform actions.

### Observe a specific notification

```python
debug.observeNotification(action="add", name="FFEffectsChangedNotification")
```

### Observe all notifications (wildcard)

```python
debug.observeNotification(action="add", name="*", logObject=True)
```

**Warning**: Wildcard observation generates high volume. Use for short discovery
sessions, then switch to specific notification names.

### Notification events

Connected clients receive:
```json
{
  "jsonrpc": "2.0",
  "method": "event",
  "params": {
    "type": "notification",
    "name": "FFEffectsChangedNotification",
    "timestamp": 1743811200.123,
    "objectClass": "FFEffectStack",
    "userInfo": {
      "FFEffectAlertTypeKey": "0"
    }
  }
}
```

### Manage observers

```python
debug.observeNotification(action="list")
debug.observeNotification(action="remove", name="FFEffectsChangedNotification")
debug.observeNotification(action="removeAll")
```

### Key FCP notifications to watch

| Notification | Fires when |
|-------------|------------|
| FFEffectsChangedNotification | Effect stack modified |
| FFEffectStackChangedNotification | Effect added/removed |
| FFActiveSelectionIsMarkerOfTypeNotification | Marker selected |
| FFAssetMediaChangedNotification | Media asset changes |
| FFAudioDuckingCurveUpdatedNotification | Audio ducking updated |
| FFBeatGridSettingsChangedNotification | Beat grid toggled |
| FFEffectRegistryChangedNotification | New effects registered |
| FFImportDidBegin | Import operation starts |
| FFQTMovieExporterFinishedNotification | Export completes |

See `fcp_symbols/notifications.txt` for the full list of 337 notification names.

## Direct Timeline Actions (`timeline.directAction`)

Calls Flexo's parameterized `action*` methods directly on `FFAnchoredTimelineModule`.
These are lower-level than the simple `timeline.action` responder-chain actions and
accept real parameters (rates, durations, flags, object handles).

### Retiming / Speed

```python
# Set exact speed rate
timeline.directAction(action="retimeSetRate", rate=0.5, ripple=True, allowVariableSpeed=True)

# Insert freeze frame at playhead
timeline.directAction(action="insertFreezeFrame")

# Speed ramp (to/from zero)
timeline.directAction(action="retimeSpeedRamp", toZero=True, fromZero=False)

# Instant replay at half speed
timeline.directAction(action="retimeInstantReplay", rate=0.5, addTitle=True)

# Jump cut (remove every Nth frame)
timeline.directAction(action="retimeJumpCut", framesToJump=5)

# Rewind effect
timeline.directAction(action="retimeRewind", speed=2.0)

# Blade at speed segment boundary
timeline.directAction(action="retimeBladeSpeedPreset")

# Reverse clip
timeline.directAction(action="retimeReverse")

# Set interpolation on retime segments
timeline.directAction(action="retimeSetInterpolation", interpolation="optical")
```

### Markers

```python
# Change marker type
timeline.directAction(action="changeMarkerType", type="chapter")  # or "todo", "note"

# Rename a marker
timeline.directAction(action="changeMarkerName", name="New Name", marker="obj_5")

# Mark todo marker as completed
timeline.directAction(action="markMarkerCompleted", completed=True, marker="obj_5")

# Remove a specific marker
timeline.directAction(action="removeMarker", marker="obj_5")
```

### Audio

```python
# Set exact volume (relative or absolute)
timeline.directAction(action="changeAudioVolume", amount=-6.0, relative=True)

# Apply audio fades
timeline.directAction(action="applyAudioFadesDirect", fadeIn=True, duration=0.5)

# Enable/disable audio playback
timeline.directAction(action="setAudioPlayEnable", enabled=False)

# Mark as background music
timeline.directAction(action="setBackgroundMusic", enabled=True)

# Detach audio (direct API)
timeline.directAction(action="detachAudioDirect")

# Align audio to video
timeline.directAction(action="alignAudioToVideoDirect")
```

### Trim / Edit

```python
# Trim to specific duration
timeline.directAction(action="trimDuration", isDelta=False)

# Extend edit over next clip
timeline.directAction(action="extendOverNextClip")

# Join through edits
timeline.directAction(action="joinThroughEdits", onEdges=True, onLeft=True)

# Remove edits (with or without gap)
timeline.directAction(action="removeEdits", replaceWithGap=True)

# Split at time
timeline.directAction(action="splitAtTime", time=3.5)

# Insert gap
timeline.directAction(action="insertGapDirect")
```

### Clip Operations

```python
# Break apart clip items
timeline.directAction(action="breakApartClipItems")

# Create compound clip (or multicam)
timeline.directAction(action="createCompoundClipDirect", multicam=False)

# Lift from primary storyline
timeline.directAction(action="liftAnchoredEdits")

# Rename clip
timeline.directAction(action="renameDirect", name="New Name")

# Delete items
timeline.directAction(action="deleteItemsInArray")

# Move to trash
timeline.directAction(action="moveClipsToTrash")
```

### Keywords / Roles

```python
# Add keywords by name
timeline.directAction(action="addKeywords", keywords=["Interview", "B-Roll"])

# Remove keywords
timeline.directAction(action="removeKeywords", keywords=["B-Roll"])

# Set role
timeline.directAction(action="setRole")
```

### Effects / Masks

```python
# Remove effect by ID
timeline.directAction(action="removeEffectByID", effectID="HEFlowTransition")

# Invert effect masks
timeline.directAction(action="invertEffectMasks")

# Toggle effect enabled
timeline.directAction(action="toggleEnabled")
```

### Multicam / Angles

```python
# Delete multicam angle
timeline.directAction(action="deleteMultiAngle")

# Rename angle
timeline.directAction(action="renameAngle", name="Camera 2")

# Audio sync multicam
timeline.directAction(action="audioSyncMultiAngle")
```

### Audition / Variants

```python
timeline.directAction(action="addVariants")
timeline.directAction(action="removeVariants")
timeline.directAction(action="finalizeVariant")
```

### Captions

```python
timeline.directAction(action="duplicateCaptions", language="es", format="SRT")
```

### Music Alignment

```python
timeline.directAction(action="alignToMusicMarkers")
timeline.directAction(action="alignClipsAtMusicMarkers", asSplit=True)
```

### Project / Library

```python
timeline.directAction(action="newProject", name="My Project")
timeline.directAction(action="newEvent", name="My Event")
timeline.directAction(action="validateAndRepair")
```

### Other

```python
timeline.directAction(action="autoReframeDirect")
timeline.directAction(action="addTransitionsDirect")
timeline.directAction(action="analyzeAndOptimize")
timeline.directAction(action="resolveLaneConflicts")
timeline.directAction(action="resolveLaneGaps")
```

### Raw selector fallback

For any action not covered by a friendly name, pass the raw ObjC selector:

```python
timeline.directAction(selector="actionValidateAndRepair:validateMode:error:")
```

The handler counts colons to determine argument count and passes nils. For full
control over arguments, use `call_method` instead.

## New Simple Actions (`timeline.action`)

These new entries in the action map use the standard responder chain pattern:

### Drop menu actions (drag-and-drop edit modes)

```python
timeline_action("dropInsert")
timeline_action("dropMenuInsert")
timeline_action("dropMenuReplace")
timeline_action("dropMenuReplaceAndStack")
timeline_action("dropMenuReplaceAtPlayhead")
timeline_action("dropMenuReplaceFromEnd")
timeline_action("dropMenuReplaceFromStart")
timeline_action("dropMenuReplaceWithRetime")
timeline_action("dropMenuAddEditsToGroup")
timeline_action("dropMenuAddToStack")
timeline_action("dropMenuCancel")
```

### Retime quality

```python
timeline_action("retimeTurnOnOpticalFlowHigh")
timeline_action("retimeTurnOnOpticalFlowMedium")
timeline_action("retimeTurnOnOpticalFlowFRC")
timeline_action("retimeTurnOnNearestNeighbor")
timeline_action("retimeRateConformOpticalFlowHigh")
```

### Cinematic / tracking

```python
timeline_action("resetCinematic")
timeline_action("addTrackerOnSource")
```

### Audio

```python
timeline_action("bakeAndRemoveOffsetChannels")
timeline_action("resetOffsetChannels")
```

### Other

```python
timeline_action("setCaptionPlaybackEnabled")
timeline_action("setCaptionPlaybackRoleUID")
timeline_action("trimEdgeAtPlayhead")
timeline_action("collapseToSpine")
timeline_action("deleteActiveVariant")
timeline_action("removeCutawayEffects")
timeline_action("toggleVerifyObjectAlignment")
```

## Symbol Dump Tool

The `tools/dump_fcp_symbols.sh` script extracts metadata from FCP's binaries that
IDA Pro decompilation misses. Run it to generate reference files:

```bash
./tools/dump_fcp_symbols.sh [output_dir]
```

Output files:

| File | Contents |
|------|----------|
| `action_selectors.txt` | All `action*` method names from all FCP frameworks |
| `toggle_selectors.txt` | All `toggle/show/hide*` methods |
| `notifications.txt` | All NSNotification names |
| `defaults_keys.txt` | All NSUserDefaults feature flag keys |
| `protocols.txt` | All protocol/delegate interface names |
| `categories.txt` | All ObjC categories |
| `swift_symbols.txt` | Demangled Swift type metadata |
| `unnamed_functions.txt` | Functions IDA couldn't symbolicate |

## Recipes

### Discover what happens when you click a menu item

```python
# 1. Trace the likely handler
debug.traceMethod(action="add", className="FFAnchoredTimelineModule",
                  selector="blade:", logStack=True)
# 2. Click the menu item in FCP
# 3. Read the trace
debug.traceMethod(action="getLog", limit=1)
# 4. Clean up
debug.traceMethod(action="removeAll")
```

### Monitor all state changes during an operation

```python
# 1. Watch key properties
debug.watch(action="add", className="NSApplication", keyPath="mainWindow")
debug.observeNotification(action="add", name="*")

# 2. Perform the operation
timeline.directAction(action="retimeSetRate", rate=0.5, ripple=True)

# 3. The watch events and notification events stream to your client
# 4. Clean up
debug.watch(action="removeAll")
debug.observeNotification(action="removeAll")
```

### Debug a crash

```python
# 1. Install handler before the problematic operation
debug.crashHandler(action="install")

# 2. Try the operation
timeline.directAction(action="retimeHoldPreset")

# 3. If it crashes, on next launch check the log
debug.crashHandler(action="getLog")
# Shows: exception name, reason, full call stack
```

### Hot-patch a fix without restarting FCP

```bash
# 1. Write and compile the patch
cat > /tmp/fix.m << 'EOF'
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
__attribute__((constructor)) void applyFix(void) {
    // Your fix here
    NSLog(@"[Fix] Applied!");
}
EOF
clang -dynamiclib -framework Foundation -undefined dynamic_lookup \
      -o /tmp/fix.dylib /tmp/fix.m
```

```python
# 2. Load into running FCP
debug.loadPlugin(action="load", path="/tmp/fix.dylib")
# 3. Test
# 4. Unload
debug.loadPlugin(action="unload", path="/tmp/fix.dylib")
```

### Find hidden feature flags

```python
# Check what defaults keys FCP has set
debug.eval(expression="NSApp.delegate", storeResult=True)
# Use the handle to explore further...

# Or check the static dump:
# See fcp_symbols/defaults_keys.txt for 426 known feature flag keys
# Set one:
debug.setConfig(key="FFCinematicToolEnable", value=True)
```

### Profile thread performance

```python
# Get detailed thread info with CPU usage
debug.threads(detailed=True)
# Look for threads with high cpuUsage values
# Cross-reference with mainThread callStack to identify bottlenecks
```
