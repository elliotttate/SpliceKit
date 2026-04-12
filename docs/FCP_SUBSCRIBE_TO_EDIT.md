# Subscribe To Edit: FCP's Subscription/Churned-Mode Infrastructure

## Overview

"Subscribe To Edit" is an internal subscription-state UI hook inside Final Cut Pro's event browser, owned by `FFEventLibraryModule`. It is **not** a user-facing editing feature, menu command, or collaboration tool. It is a debug/testing button for Apple's **SPV (Shared Project Viewing) subscription system** — the infrastructure that governs what a churned (lapsed) subscriber can and cannot do in FCP.

The button, the churned-mode layout, the restricted command set, and the subscription content warnings are all fully compiled into the shipping binary but currently dormant. The system is waiting for the day Apple ships a subscription-based FCP model.

---

## The Subscription Model Architecture

FCP defines three app model tiers, tracked via `PASApp.model`:

| Model | Check | Meaning |
|-------|-------|---------|
| **Model 1** | `PCApp.isModel1` | One-time purchase (current Mac App Store model) |
| **Model 2** | `PCApp.isModel2` | Subscription-based ("Apple Creator Studio" bundle) |
| **Trial** | `PCApp.isTrial` | Trial/evaluation mode |

Source: `+[PCApp isModel1]` at `ProCore/0xC8BCC`, `+[PCApp isModel2]` at `ProCore/0xC8C0A`, `+[PCApp isTrial]` at `ProCore/0xC8C48`. All three delegate to `PASApp.sharedInstance.model`.

The `isRunningSubscriptionApp` check in `CloudContentBundleIDChecker` is equivalent to `isModel2` — it checks whether the running bundle is the subscription variant.

---

## SPV Feature Gate

The entire subscription-aware UI is gated behind the **SPV feature flag**:

- **`PCAppFeature.isSPVEnabled`** (ProCore) — **hardcoded to return `1`**. The feature is compiled in at the framework level.
- **`Flexo.isSPVEnabled`** — checks `PCFeatureFlags.checkFeature:` with key `"FlexoConfig.isSPVEnabled"`, which reads from the runtime feature flags dictionary. Runtime-toggleable.
- **Debug toggle**: `PEAppDebugPreferencesModule.addSPVToggle` creates a checkbox labeled **"Enable SPV (next launch)"** bound to `values.isSPVEnabled` in the experimental settings panel.

Source: `+[PCAppFeature isSPVEnabled]` at `ProCore/0x7EA69`, `+[Flexo isSPVEnabled]` at `Flexo/0x2F240`, `-[PEAppDebugPreferencesModule addSPVToggle]` at `Final Cut Pro/0x100077F40`.

### SPV Default State in the Binary

SPV is defaulted to **true** at three independent levels:

1. **`__GLOBAL__sub_I_FlexoConfig.mm`** (line 486): `sDefaultFeatureFlags["FlexoConfig.isSPVEnabled"] = kCFBooleanTrue`
2. **`+[PCAppFeature isSPVEnabled]`**: Hardcoded to `return 1`
3. **`+[PCAppFeature registerFeatureDefaults]`**: Registers `isSPVEnabled = YES` into `NSUserDefaults`

During launch, `_main` (line 101-103) reads `PCAppFeature.isSPVEnabled` (hardcoded `1`) and feeds it into the feature dictionary. The `finishInitWithFeatureFlags:` block (`Flexo/0x2E480`) prepends `"FlexoConfig."` to each key:

```c
// ___36+[Flexo finishInitWithFeatureFlags:]_block_invoke
v4 = @"FlexoConfig.".stringByAppendingString(key);
mutableCopy.setObject(value, forKey: v4);
```

So `"isSPVEnabled"` from `_main` becomes `"FlexoConfig.isSPVEnabled" = true` in the final `PCFeatureFlags._features` dictionary. Combined with the `sDefaultFeatureFlags` which also has `FlexoConfig.isSPVEnabled = true`, the feature is doubly enabled.

---

## The Subscribe To Edit Button

### Creation

The button is created in `-[FFEventLibraryModule setupSubscribeToEditButton]` (Flexo/0x70DF60):

- Allocates an `NSButton` with control size 3, button type 6 (toggle)
- Title: `"Subscribe To Edit"` (non-localized via `FFNonLocalizedStringForString`)
- Target: `self` (the `FFEventLibraryModule`)
- Action: `subscribeToEditAction:`
- Added as a subview of the module's view

The button is only created during `-[FFEventLibraryModule init]` (line 61) when `Flexo.isSPVEnabled` is true.

### Visibility Logic

In `-[FFEventLibraryModule postLayout:]` (Flexo/0x70FD20), when SPV is enabled:

1. `FFSubscriptionUtils.hasActiveLicense_FCP` is queried
2. If license is **active**: the normal `_sidebarControlButtonView` is shown, the Subscribe To Edit button is **hidden**
3. If license is **not active**: the normal sidebar control is hidden, the Subscribe To Edit button is **shown**

The button's state is always reset to 1 (checked) in `postLayout:`.

### Action Handler

`-[FFEventLibraryModule subscribeToEditAction:]` (Flexo/0x7108B0):

1. Gets `NSApp.delegate` (which is `PEAppController`)
2. Checks if the delegate responds to `toggleMockedChurnedMode`
3. If it does, performs that selector

The word "Mocked" is key — this is a **test harness** for simulating subscription lapse. **No implementation of `toggleMockedChurnedMode` exists anywhere in the decompiled binary**, confirming it was either stripped from release builds or only existed in internal debug builds. If users see this button, they are seeing internal churn-test UI rather than an intended purchase flow.

---

## License State Management

`PEAppController._hasActiveLicense` is a simple boolean ivar with a getter/setter pair:

- **Read**: `-[PEAppController hasActiveLicense]` at `0x100066200` — returns `self->_hasActiveLicense`
- **Write**: `-[PEAppController setHasActiveLicense:]` at `0x100066210`
- **Update callback**: `-[PEAppController licenseStatusChangedTo:]` at `0x10004A2E0` — queries `POFStoreManagerAdapter.hasActiveLicense` and updates the ivar

The Flexo framework accesses this indirectly through `FFSubscriptionUtils`:

- **`+[FFSubscriptionUtils hasActiveLicense_FCP]`** (Flexo/0x5D5050): Uses `NSInvocation` to dynamically call `hasActiveLicense` on `NSApp.delegate`. Defaults to `true` if the delegate doesn't respond. This deliberate decoupling means Flexo doesn't link directly against ProEditor types.
- **`+[FFSubscriptionUtils isActionDisabled_FCP:]`** (Flexo/0x5D5130): Same NSInvocation pattern, forwards a selector argument to `isActionDisabled:` on the delegate.

### Store Manager and License Status

`POFStoreManagerAdapter.hasActiveLicense` (at `0x24960`) decodes a license status integer via a bitmask:

```c
v2 = licenseStatus();
if ((v2 - 2) >= 6)        // status < 2 or > 7
    return v2 == 8;        // only status 8 returns true
v4 = 39;                   // binary: 100111
_bittest(&v4, v2 - 2);    // test bit (v2-2) of 39
```

| License Status | hasActiveLicense | Meaning |
|---------------|-----------------|---------|
| 0 | false | Unknown/uninitialized |
| 1 | false | Not purchased |
| 2 | **true** | Licensed |
| 3 | **true** | Licensed (variant) |
| 4 | **true** | Licensed (variant) |
| 5 | false | Lapsed/churned |
| 6 | false | Lapsed/churned |
| 7 | **true** | Licensed (variant) |
| 8 | **true** | Licensed (special) |

### NullStoreManager Fallback

When the real store manager singleton hasn't been initialized, the license resolver (`sub_263E0`) falls back to creating a `NullStoreManager`:

```c
if (storedStoreManager == nil) {
    NullStoreManager *null = swift_allocObject(NullStoreManager);
    null->field2 = 0;
    null->field3 = swiftEmptyArrayStorage;
    null->field4 = 2;  // purchaseStatus = 2
    return null.licenseStatus;  // via protocol witness
}
```

### Bypass/Mock Store (Persisted in Defaults)

The onboarding store layer has its own bypass mechanism. `-[POFStoreManagerAdapter init]` (at `0x244C0`) **always** constructs a `BypassPurchaseStorage`:

```c
v2 = type metadata accessor for BypassPurchaseStorage(0);
v3 = objc_allocWithZone(v2);
v4 = [v3 init];
v5 = [self initWithSubscriptionStoring: v4];
```

That storage reads and writes its state from `NSUserDefaults`:

- **`-[POFBypassPurchaseStorage useBypassStoreManager]`** (0x3FE60): reads a boolean key from defaults
- **`-[POFBypassPurchaseStorage useStoreManagerType]`** (0x3F480): reads an integer key from defaults
- **`-[POFBypassPurchaseStorage setBypassLicenseStatus:]`** (0x3FAB0): writes an integer license status to defaults

A machine with stale bypass or mock-store defaults can present as unlicensed even if that was only ever intended for internal testing.

---

## Launch Flow

### When SPV is Enabled

1. **`PEAppController.init`** (nib loading):
   ```c
   if (Flexo.isSPVEnabled) {                        // SPV always defaults true
       storeManager = alloc_init POFStoreManagerAdapter;
       _hasActiveLicense = storeManager.hasActiveLicense;  // SYNCHRONOUS
   }
   ```

2. **`applicationDidFinishLaunching:`** — enters the SPV onboarding path:
   - Shows "Receipt Validation" modal progress
   - Runs `POFDesktopOnboardingCoordinator.runFlow`
   - Completion block (`.460`) executes:
     ```c
     storeManager.addObserver(self);           // register for license changes
     _hasActiveLicense = storeManager.hasActiveLicense;  // re-check
     if (!storeManager.hasActiveLicense) {
         NSApp.terminate(nil);                 // NO LICENSE → QUIT APP
     }
     ```

3. **`applicationContinueDidFinishLaunching:`** → **`presentMainWindowOnAppLaunch:`** (line 375):
   ```c
   if (isSPVEnabled && !hasActiveLicense) {
       load churnedModeModuleLayout;
       changeToRestrictedCommandSet;
       setCommandMenuDisabled: true;
   }
   ```
   This builds the UI, triggering `FFEventLibraryModule.init` (creates button) and `postLayout:` (shows/hides button).

### When SPV is Not Enabled

Goes directly to `applicationContinueDidFinishLaunching:` — no receipt validation, no onboarding, no license check, no terminate path.

---

## What Churned Mode Looks Like

When SPV is enabled and `hasActiveLicense` returns false, FCP enters a severely restricted state:

### 1. Restricted Workspace Layout

A special `churnedModeModuleLayout` is applied instead of the user's saved layout:

- Layout identified by UUID `ECD4C2F8-B60E-4314-8292-807B5236DBBE` (churned) vs `C8AFE9FB-EF4C-4036-95E1-B7FFAC353E37` (regular)
- `PEChurnedLayoutCreator` generates this layout from a hardcoded XML string (`+[PEChurnedLayoutCreator churnedLayoutContents]`)
- The layout file is written to disk and can be cleaned up via `+[PEChurnedLayoutCreator removeChurnedLayoutFile]`

Source: `-[PEModuleLayoutManager churnedModeModuleLayout]` at `0x100039000`, `-[PEAppController switchUIForChurnedMode:]` at `0x10004A330`.

### 2. Stripped Toolbar

`-[PEAppController prepareToolbarItems]` (0x10004A0A0) reduces the toolbar based on license state:

**Licensed (12 items):**
1. Create Stuff
2. Import
3. Keywords
4. Background Tasks
5. External Provider
6. Flexible Spacer
7. Dual Monitor
8. Show Organizer
9. Show Editor
10. Show Inspector
11. Spacer
12. Share

**Unlicensed (2 items):**
1. Flexible Spacer
2. Share

You can browse and export — that's it.

### 3. Tool Palette Hidden

`-[PEPlayerContainerModule switchModuleUIForChurnedMode:]` (0x10001C400) hides `_toolPaletteView` entirely when entering churned mode. The blade tool, trim tool, range selection — all gone from the viewer.

### 4. Command Menu Disabled

`LKCommandsController.commandMenuDisabled` is set to `true`, preventing command palette / keyboard shortcut access.

### 5. Restricted Command Set

This is the most granular gate. Two separate mechanisms work together:

#### Gate 1: Command Unregistration

`-[PEAppController changeToRestrictedCommandSet]` (0x100049E40) iterates all "regular pro commands" (a snapshot of the full command registry, cached by `+[PEAppController regularProCommands]`). For each command, it checks the command's `identifier` against a private allowlist set (`off_1001763B8`). **Everything not in the allowlist is unregistered from `LKCommandsController`.**

Restoration is handled by `-[PEAppController changeToRegularCommandSet]`, which re-registers the cached snapshot.

#### Gate 2: Per-Action Selector Validation

`-[PEAppController isActionDisabled:]` (0x100049D50) checks individual action selectors against a separate private set (`off_1001763A0`). This is called from three `validateUserInterfaceItem:` implementations:

- `PEAppController` — app-level menu items
- `PEPlayerContainerModule` — player/viewer controls
- `FFEventLibraryModule` — browser/organizer actions

Both sets are static data references in the binary. The command-side allowlist was recovered from the live app (see below); the selector-side set is inferred from static code structure.

---

## Recovered Restricted Command Set (Live App)

Using SpliceKit against the running FCP process, `changeToRestrictedCommandSet` was temporarily invoked, the command registry was diffed, and regular mode was restored.

**Result: 563 normal commands, 183 restricted-mode survivors, 380 removed.**

### Representative Removals (editing surface stripped)

| Category | Removed Commands |
|----------|-----------------|
| **Creation** | NewLibrary, NewProject, NewEvent, Import, InsertMedia, AppendWithSelectedMedia, OverwriteWithSelectedMedia |
| **Titles & Markers** | AddBasicTitle, AddMarker, AddChapterMarker, AddToDoMarker, AddTransition |
| **Color** | AddColorBoardEffect, AddColorCurvesEffect, AddColorWheelsEffect, AddHueSaturationEffect, AddEnhanceLightAndColorEffect |
| **Editing** | Paste, PasteAsConnected, PasteAllAttributes, Delete, DeleteSelectionOnly, TrimEnd |
| **Clip Operations** | CreateCompoundClip, DetachAudio, EditRoles, FindAndReplaceTitleText |
| **Speed** | RetimeFast2x, RetimeSlow50, RetimeReverseClip, RetimeHold, RetimeCustomSpeed |
| **Panels** | ToggleTimeline, ToggleInspector, ToggleKeywordEditor, ShowRetimeEditor, ShowAudioCurveEditor |

### Representative Survivors (playback, browsing, export, utility)

| Category | Surviving Commands |
|----------|-------------------|
| **Library** | OpenLibrary, CloseLibrary, CloseProject, CloseWindow |
| **Export** | ExportXML, ExportCaptions, ShareDefaultDestination, SendToCompressor, RenderSelection |
| **File Management** | RelinkFiles, RelinkProxyFiles, RevealInFinder, MoveToTrash |
| **Playback** | PlayPause, PlayFromStart, PlayReverse, JumpToStart, JumpToEnd, JumpForward10Frames, JumpBackward10Frames |
| **View** | ZoomIn, ZoomOut, ZoomToFit |
| **UI Panels** | ToggleOrganizer, ToggleEventViewer, ToggleEventsLibrary, ToggleSkimming, ToggleAudioScrubbing |
| **Selection** | SelectAll, DeselectAll, Copy, Cut, UndoChanges, RedoChanges |

### Notable Anomalies

A few survivors are surprising: **Cut**, **ImportXML**, **MoveToTrash**, **Nudge\***, **SetSelectionStart/End**, and **ConsolidateFiles** are still present. This is not a pure read-only shell — it is a **manually curated restricted subset** that preserves some editing and organizational capabilities.

---

## Subscription Content Warnings

When loading a sequence, `-[PEEditorContainerModule loadEditorForSequence:]` checks for subscription-gated content:

1. Calls `checkForSubscriptionCloudContentItemsForSequence:` (0x100019660)
2. This queries `FFCloudContentHelper.copySubscriptionEffectIDsInProject:`, which:
   - Gets all effect references in the project
   - Intersects with `FFEffect.allSubscriptionCloudEffectIDs` — effects with the cloud content prefix **and** `kFFEffectProperty_RequiresSubscription == true`
3. If subscription effects are found and `isRunningSubscriptionApp` is false:
   - Shows an `NSAlert` with localized title `PESubscriptionContentAlertTitle` and text `PESubscriptionContentAlertText` (from `PELocalizable_SPV`)
   - Two buttons: a confirm button and "Not Now"
   - Confirm opens **https://www.apple.com/apple-creator-studio**

---

## SPV Menu Customization

`-[PEAppController customizeMenuForSPV]` (0x10006A3C0) adds subscription-related menu items:

### Manage Subscription
- Added only when `PCApp.isModel2` is true (subscription model)
- Inserted below "Download Content Library" in the menu
- Action: `manageSubscription:` — opens a localized URL (`PEManageSubscriptionURL` from `PELocalizable_SPV`)
- Also hides the "FCP for iPad" promo (`setShouldHideFCPForIpadPromo: true`)

### Learn About Suite
- Added near the "About" menu item for all SPV users
- Action: `learnAboutSuite:` — opens different URLs by model:
  - Model 1 / Trial: `PELearnAboutSuiteURL_OTP` (one-time purchase upsell)
  - Model 2: `PELearnAboutSuiteURL_SUB` (subscription management)

Source files reference path: `ProEditor-44000.5.223/Source/Subscription/PEAppController+SPVMenu.m`

---

## Bug Analysis: Why "Subscribe To Edit" Appears For Some Users

### Primary Bug: Stale License State / No UI Resync

This is the strongest identified bug. The license change callback `licenseStatusChangedTo:` (0x10004A2E0) re-reads the store state, but it **only calls `setHasActiveLicense:`** — a bare ivar write:

```c
// -[PEAppController licenseStatusChangedTo:]
v3 = self.storeManager;
v4 = storeManager.hasActiveLicense;
self.setHasActiveLicense(v4);  // just sets _hasActiveLicense, nothing else
```

The method that actually flips the app between restricted and regular UI is `-[PEAppController switchUIForChurnedMode:]` (0x10004A330) — but **no static callsites to `switchUIForChurnedMode:` were found outside of the initial launch path**. That means:

- A **transient false** license state during launch can put the organizer into the "Subscribe To Edit" branch
- A **later true** license state updates the ivar but does not force the UI back
- No mechanism was found that calls `switchUIForChurnedMode: false` to restore the full UI after the license resolves

### Secondary Bug: Button Visibility Tied to Layout, Not License Mutation

The Subscribe To Edit button is only shown/hidden during organizer layout passes, not in response to license changes. In `postLayout:` (Flexo/0x70FD20, line 24):

```c
if (Flexo.isSPVEnabled) {
    v7 = FFSubscriptionUtils.hasActiveLicense_FCP;
    _sidebarControlButtonView.setHidden(v7 == 0);
    _subscribeToEditButton.setHidden((unsigned int)v7);
    _subscribeToEditButton.setState(1);
}
```

If `_hasActiveLicense` changes without forcing a layout pass on `FFEventLibraryModule`, the wrong control remains visible. There is no `NSNotification`, KVO observation, or explicit `setNeedsLayout` call that bridges the `setHasActiveLicense:` ivar write to a relayout of the organizer module.

### Contributing Factor: SPV Flag Persisted via User Defaults

SPV is explicitly machine-state driven through user defaults. The debug preferences checkbox at `-[PEAppDebugPreferencesModule addSPVToggle]` (0x100077F40) is bound to `values.isSPVEnabled`:

```c
[button bind:@"value" toObject:sharedUserDefaultsController
    withKeyPath:@"values.isSPVEnabled" options:...];
```

Once that default is set on a given machine (intentionally or accidentally), `-[FFEventLibraryModule init]` (line 61) will create the button on every subsequent launch. This cleanly explains why only some machines see the button — it's a per-machine defaults artifact.

### Contributing Factor: Persisted Mock-Store / Bypass State

The onboarding store layer has its own bypass mechanism. `-[POFStoreManagerAdapter init]` (0x244C0) **always** constructs `BypassPurchaseStorage`, and that storage reads/writes its state from `NSUserDefaults`:

| Method | Address | What it does |
|--------|---------|-------------|
| `-[POFBypassPurchaseStorage useBypassStoreManager]` | 0x3FE60 | Reads boolean from defaults |
| `-[POFBypassPurchaseStorage useStoreManagerType]` | 0x3F480 | Reads integer from defaults |
| `-[POFBypassPurchaseStorage setBypassLicenseStatus:]` | 0x3FAB0 | Writes integer license status to defaults |

A machine with stale bypass or mock-store defaults can present as unlicensed even if that was only ever intended for testing. These defaults would survive app updates and persist across sessions.

### Contributing Factor: Synchronous Store Check Race

In `PEAppController.init`, the store check is synchronous on a freshly allocated adapter:

```c
storeManager = [[POFStoreManagerAdapter alloc] init];
_hasActiveLicense = storeManager.hasActiveLicense;  // immediate
```

The underlying license resolver (`sub_263E0`) accesses a global store manager singleton. If it's not ready, it falls back to `NullStoreManager`. Depending on what license status the NullStoreManager returns through its protocol witness table, `hasActiveLicense` could return false for status values 0, 1, 5, or 6.

The store observer is only registered later in the `applicationDidFinishLaunching` completion block (`.460`). Any license transitions that occur between init and observer registration are silently missed.

### Contributing Factor: Feature Flag Key Inconsistency

The static SPV bootstrap path has an inconsistency. `_main` (line 103) seeds the feature dictionary with key `"isSPVEnabled"`, while `Flexo.isSPVEnabled` checks `"FlexoConfig.isSPVEnabled"`. The `finishInitWithFeatureFlags:` block prepends `"FlexoConfig."` to bridge this gap, but the indirection creates a fragile dependency — if the block doesn't run or runs on a different set of keys, the flag could resolve differently than intended.

In the live app inspected during analysis, `Flexo.isSPVEnabled` returned `false`, so this part may be build-specific or reflect decompiler noise rather than a confirmed production bug.

---

## Most Likely Root Cause

**A machine-specific SPV flag or mock-store default got set, and then the UI got stuck in the churned/unlicensed presentation because license changes do not visibly drive a full UI resync.**

The chain is:
1. `isSPVEnabled` is true (either from static defaults or a persisted user default)
2. The store check returns false at init time (stale bypass defaults, transient StoreKit failure, or mock-store state)
3. The button is created and shown during `postLayout:`
4. The license later resolves to true via `licenseStatusChangedTo:` → `setHasActiveLicense:`
5. But `setHasActiveLicense:` is just an ivar write — it doesn't call `switchUIForChurnedMode:`, doesn't force a relayout, and doesn't hide the button
6. The button remains visible until the next `postLayout:` pass (which may not happen without user interaction that triggers layout)

---

## Can Workspace Modifications Cause This?

**Not by itself, no.**

The button is created by `FFEventLibraryModule.init` based on `Flexo.isSPVEnabled`, and shown/hidden by `postLayout:` based on `hasActiveLicense`. Neither of these reads workspace files. The root causes are the SPV feature flag and the app's cached license state, not the workspace.

Workspace files can contribute **indirectly**. Final Cut's workspace system uses `.fcpworkspace` layout files managed by `PEModuleLayoutManager`. The churned path loads a special workspace via `churnedModeModuleLayout` (UUID `ECD4C2F8-B60E-4314-8292-807B5236DBBE`), and `switchUIForChurnedMode:` swaps to that UUID and the restricted command set.

- **Editing normal workspace files**: unlikely to be the root cause
- **Corrupting the churned workspace layout**: could make the churned UI persist or look wrong once the app is already in churned mode
- **Actual root cause to investigate first**: `isSPVEnabled` default, persisted mock-store/bypass defaults, and the stale `_hasActiveLicense` / no-UI-resync bug

---

## Diagnostic Checklist for Affected Machines

### Step 1: Check SPV Feature Flag

```bash
defaults read com.apple.FinalCut isSPVEnabled
```

If this returns `1`, SPV is explicitly enabled on this machine. This is the gate that creates the button.

### Step 2: Check Bypass/Mock-Store Defaults

```bash
defaults read com.apple.FinalCut | grep -i -E "bypass|mock|store|license|subscription|churned"
```

Look for any keys related to `BypassPurchaseStorage`, `useBypassStoreManager`, `useStoreManagerType`, or `bypassLicenseStatus`. Any non-default values here indicate stale testing state that could cause a false "unlicensed" report.

### Step 3: Verify Live License State

If SpliceKit is available:

```
bridge_status()
get_object_property("NSApp.delegate", "_hasActiveLicense")
```

Or via runtime introspection:
- `PEAppController._hasActiveLicense` — should be `true` for a purchased copy
- `POFStoreManagerAdapter.hasActiveLicense` — the store's current answer
- `POFStoreManagerAdapter.licenseStatus` — the raw status integer (2/3/4/7/8 = licensed)

### Step 4: Verify Button State

If SpliceKit is available, navigate to the live `FFEventLibraryModule`:

```
# Get organizer module
call_method_with_args("NSApp", "delegate", "[]", false, true)
# Navigate: delegate -> mediaEventOrganizerContainer -> activeOrganizerModule
# Check: _subscribeToEditButton (should be nil or hidden)
# Check: _sidebarControlButtonView (should exist and not hidden)
```

### Step 5: Check for Stale Churned Layout

```bash
# Look for churned layout files
find ~/Library/Application\ Support/Final\ Cut\ Pro -name "*.fcpworkspace" | head -20
```

The churned layout UUID is `ECD4C2F8-B60E-4314-8292-807B5236DBBE`. If a workspace file references this UUID and the app isn't supposed to be in churned mode, it's a stale artifact.

### Step 6: Nuclear Reset (if needed)

```bash
# Remove SPV flag
defaults delete com.apple.FinalCut isSPVEnabled

# Remove any bypass/mock-store defaults (check exact key names first)
defaults delete com.apple.FinalCut <bypass-key-name>

# Remove churned layout files
# (identify specific files first before deleting)
```

**Note**: The exact NSUserDefaults key names for the bypass storage are generated by Swift `String._bridgeToObjectiveC()` calls and are not directly visible in the decompilation. The `grep` in Step 2 should surface them if they exist.

---

## Current Live State

Verified via SpliceKit runtime introspection:

| Check | Result |
|-------|--------|
| `FFEventLibraryModule._subscribeToEditButton` | `nil` (not created) |
| `FFEventLibraryModule._sidebarControlButtonView` | Exists, not hidden |
| `PEAppController.hasActiveLicense` | `false` (normal for non-subscription FCP) |
| `PEAppController responds to toggleMockedChurnedMode` | `false` (not implemented) |
| `LKCommandsController.commandMenuDisabled` | `false` |
| `newLibrary:` treated as disabled | `false` |
| `Flexo.isSPVEnabled` | `false` (not enabled in this session) |

The infrastructure is fully compiled in but dormant. The SPV feature flag is not enabled in the current session, so the button is never created, the restricted command set is never applied, and the churned layout is never loaded.

---

## Key Classes & Source Files

| Class | Role |
|-------|------|
| `FFEventLibraryModule` | Owns the Subscribe To Edit button, visibility logic |
| `FFSubscriptionUtils` | Bridge to app delegate for license/action checks |
| `FFCloudContentHelper` | Identifies subscription-gated effects in projects |
| `FFEffect` | Tracks `kFFEffectProperty_RequiresSubscription` per effect |
| `PEAppController` | License state, churned-mode switching, toolbar, menus |
| `PEAppController(ChurnedMode)` | Category with `regularProCommands`, command set switching |
| `PEAppController(SPVMenu)` | Category with subscription menu items |
| `PEChurnedLayoutCreator` | Generates the restricted workspace layout XML |
| `PEModuleLayoutManager` | Applies churned vs normal workspace layouts |
| `PEPlayerContainerModule` | Hides tool palette in churned mode |
| `PEEditorContainerModule` | Subscription content checks on sequence load |
| `PEAppDebugPreferencesModule` | SPV toggle in experimental settings |
| `LKCommandsController` | Command registry, `commandMenuDisabled` flag |
| `PCAppFeature` / `PCFeatureFlags` | SPV feature flag evaluation |
| `PCApp` / `PASApp` | App model tier (Model 1 / Model 2 / Trial) |
| `POFStoreManagerAdapter` | Store framework bridge for license state |
| `POFBypassPurchaseStorage` | Mock/bypass store state in NSUserDefaults |
| `CloudContentBundleIDChecker` | Maps `isRunningSubscriptionApp` to `isModel2` |

### Decompiled Source References

| Function | Address |
|----------|---------|
| `-[FFEventLibraryModule setupSubscribeToEditButton]` | Flexo/0x70DF60 |
| `-[FFEventLibraryModule subscribeToEditAction:]` | Flexo/0x7108B0 |
| `-[FFEventLibraryModule postLayout:]` | Flexo/0x70FD20 |
| `-[FFEventLibraryModule validateUserInterfaceItem:]` | Flexo/0x710EC0 |
| `+[FFSubscriptionUtils hasActiveLicense_FCP]` | Flexo/0x5D5050 |
| `+[FFSubscriptionUtils isActionDisabled_FCP:]` | Flexo/0x5D5130 |
| `+[FFEffect allSubscriptionCloudEffectIDs]` | Flexo/0x4F8120 |
| `+[FFCloudContentHelper copySubscriptionEffectIDsInProject:]` | Flexo/0xDBCB60 |
| `__GLOBAL__sub_I_FlexoConfig.mm` | Flexo/0x2F750 |
| `+[Flexo isSPVEnabled]` | Flexo/0x2F240 |
| `+[Flexo finishInitWithFeatureFlags:]` | Flexo/0x2E3A0 |
| `___36+[Flexo finishInitWithFeatureFlags:]_block_invoke` | Flexo/0x2E480 |
| `-[PEAppController init]` | Final Cut Pro/0x10004A890 |
| `-[PEAppController isActionDisabled:]` | Final Cut Pro/0x100049D50 |
| `-[PEAppController changeToRestrictedCommandSet]` | Final Cut Pro/0x100049E40 |
| `+[PEAppController regularProCommands]` | Final Cut Pro/0x100049DC0 |
| `-[PEAppController switchUIForChurnedMode:]` | Final Cut Pro/0x10004A330 |
| `-[PEAppController prepareToolbarItems]` | Final Cut Pro/0x10004A0A0 |
| `-[PEAppController presentMainWindowOnAppLaunch:]` | Final Cut Pro/0x100049D50+ |
| `-[PEAppController applicationDidFinishLaunching:]` | Final Cut Pro/0x10004E480 |
| `___49-[PEAppController applicationDidFinishLaunching:]_block_invoke.460` | Final Cut Pro/0x10004E680 |
| `-[PEAppController licenseStatusChangedTo:]` | Final Cut Pro/0x10004A2E0 |
| `-[PEAppController setHasActiveLicense:]` | Final Cut Pro/0x100066210 |
| `-[PEAppController customizeMenuForSPV]` | Final Cut Pro/0x10006A3C0 |
| `-[PEAppController addManageSubscriptionToMenu:]` | Final Cut Pro/0x10006A620 |
| `-[PEAppDebugPreferencesModule addSPVToggle]` | Final Cut Pro/0x100077F40 |
| `-[PEModuleLayoutManager churnedModeModuleLayout]` | Final Cut Pro/0x100039000 |
| `-[PEPlayerContainerModule switchModuleUIForChurnedMode:]` | Final Cut Pro/0x10001C400 |
| `-[PEEditorContainerModule checkForSubscriptionCloudContentItemsForSequence:]` | Final Cut Pro/0x100019660 |
| `+[PCAppFeature isSPVEnabled]` | ProCore/0x7EA69 |
| `+[PCAppFeature registerFeatureDefaults]` | ProCore/0x7E9F4 |
| `+[PCFeatureFlags checkFeature:]` | ProCore/0x61A6F |
| `-[PCFeatureFlags checkFeature:]` | ProCore/0x619DB |
| `-[POFStoreManagerAdapter init]` | ProOnboardingFlowModelOne/0x244C0 |
| `-[POFStoreManagerAdapter hasActiveLicense]` | ProOnboardingFlowModelOne/0x24960 |
| `-[POFStoreManagerAdapter licenseStatus]` | ProOnboardingFlowModelOne/0x24A20 |
| `-[POFBypassPurchaseStorage useBypassStoreManager]` | ProOnboardingFlowModelOne/0x3FE60 |
| `-[POFBypassPurchaseStorage useStoreManagerType]` | ProOnboardingFlowModelOne/0x3F480 |
| `-[POFBypassPurchaseStorage setBypassLicenseStatus:]` | ProOnboardingFlowModelOne/0x3FAB0 |
