# Sentry Setup

This repo now has Sentry reporting in two places:

- `splicekit-fcp-runtime`: the injected `SpliceKit` dylib running inside Final Cut Pro
- `splicekit-patcher`: the SwiftUI patcher app

The runtime integration is the important one for crash coverage. Once SpliceKit loads into Final Cut Pro and initializes Sentry, crashes from that host process should be reported to the runtime project, even when the root cause is not obviously inside SpliceKit. Use the runtime tags to separate "SpliceKit probably caused this" from "FCP happened to crash while SpliceKit was loaded."

## Hardcoded DSN

Both the patcher app and the injected runtime now use a single hardcoded DSN:

```text
https://56fa8ecde3c66d354606805ac2064c54@o4511243520966656.ingest.us.sentry.io/4511243525423104
```

There is no build-time or runtime DSN override path anymore. If you ever want to point SpliceKit at a different Sentry project, change the constant in:

- `patcher/SpliceKit/Models/PatcherSentry.swift`
- `Sources/SpliceKitSentry.m`

## Build-Time Environment Variables

`Scripts/generate_sentry_config.sh` still writes `SpliceKitSentryConfig.plist`, but that plist now only carries non-DSN metadata.

- `SPLICEKIT_SENTRY_ENVIRONMENT`
  Optional. Usually `development`, `staging`, or `production`. Defaults to `production`.

Example:

```bash
export SPLICEKIT_SENTRY_ENVIRONMENT='development'
```

## Release-Time Environment Variables

These are used by `release.sh` when uploading dSYMs with `sentry-cli`.

- `SENTRY_AUTH_TOKEN`
- `SENTRY_ORG`
- `SENTRY_PATCHER_PROJECT`
  Optional. Defaults to `splicekit-patcher`.
- `SENTRY_RUNTIME_PROJECT`
  Optional. Defaults to `splicekit-fcp-runtime`.

Example:

```bash
export SENTRY_AUTH_TOKEN='<token>'
export SENTRY_ORG='your-org'
export SENTRY_PATCHER_PROJECT='splicekit-patcher'
export SENTRY_RUNTIME_PROJECT='splicekit-fcp-runtime'
```

## Normal Development Flow

1. Ensure the Sentry SDK is present:

```bash
bash Scripts/ensure_sentry_framework.sh
```

2. Export the environment if you want something other than `production`:

```bash
export SPLICEKIT_SENTRY_ENVIRONMENT='development'
```

3. Build the patcher app:

```bash
xcodebuild -project patcher/SpliceKit.xcodeproj \
  -scheme SpliceKit \
  -configuration Release \
  -derivedDataPath patcher/build \
  ONLY_ACTIVE_ARCH=NO \
  build
```

During the build:

- `patcher/scripts/build_dylib.sh` ensures `patcher/Frameworks/Sentry.framework` exists and builds the prebuilt runtime payload.
- `patcher/scripts/bundle_resources.sh` writes `SpliceKitSentryConfig.plist` into the app bundle.

4. Patch or update Final Cut Pro with the built patcher app.

During patch/update, the patcher copies `SpliceKitSentryConfig.plist` into:

```text
Final Cut Pro.app/Contents/Frameworks/SpliceKit.framework/Versions/A/Resources/SpliceKitSentryConfig.plist
```

That makes the runtime environment and release metadata available inside the injected dylib.

## Manual Runtime Config For `make deploy`

If you deploy the dylib directly with `make deploy` instead of using the patcher UI, generate a standalone runtime config plist first:

```bash
mkdir -p "$HOME/Library/Application Support/SpliceKit"
bash Scripts/generate_sentry_config.sh \
  "$HOME/Library/Application Support/SpliceKit/SpliceKitSentryConfig.plist"
```

`make deploy` will copy that plist into the installed framework resources if it exists.

## What Gets Reported

### Patcher

The patcher captures:

- patcher crashes
- explicit patch/update/launch failures
- breadcrumbs from `patcher.log`
- a synthetic follow-up event on next launch if the previous patcher run crashed

Useful tags and context:

- `component=patcher`
- `patcher_context`
- `splicekit_version`
- log tail from `patcher.previous.log`

### Runtime

The injected runtime captures:

- crashes in Final Cut Pro after SpliceKit has loaded and initialized Sentry
- uncaught Objective-C exceptions in that host process
- explicit nonfatal failures from SpliceKit startup and RPC handling
- breadcrumbs mirrored from `SpliceKit_log(...)`
- a synthetic follow-up event on next launch if the previous runtime session crashed

Useful runtime tags:

- `component=runtime`
- `host_app=Final Cut Pro`
- `splicekit_loaded=true`
- `splicekit_version`
- `fcp_version`
- `startup_phase`
- `last_rpc_method`
- `splicekit_in_stack=true|false`

`splicekit_in_stack=true` is the quickest filter for likely SpliceKit-caused crashes. Leave the broader crash stream on, because unrelated-looking FCP crashes are sometimes regressions introduced by injection or swizzles.

## Symbol Uploads

The release script now uploads both debug symbol sets:

- `build/SpliceKit.dSYM`
- `patcher/build/Build/Products/Release/SpliceKit.app.dSYM`

Run a release like this:

```bash
export SPLICEKIT_SENTRY_ENVIRONMENT='production'
export SENTRY_AUTH_TOKEN='...'
export SENTRY_ORG='your-org'

./release.sh 3.1.149 "Your release notes here"
```

If `SENTRY_AUTH_TOKEN` or `SENTRY_ORG` is missing, the release still builds, but symbol upload is skipped.

## Verifying The Integration

### Verify the patcher side

1. Build the patcher.
2. Launch the patcher outside the debugger.
3. Trigger a known patcher error path or add a temporary `PatcherSentry.captureMessage(...)`.
4. Confirm the event lands in `splicekit-patcher`.

### Verify the runtime side

1. Build normally.
2. Patch Final Cut Pro with the new app, or run `make deploy` after generating the standalone plist.
3. Launch Final Cut Pro without the debugger attached.
4. Trigger a known runtime error path or temporary `SpliceKit_sentryCaptureMessage(...)`.
5. Confirm the event lands in `splicekit-fcp-runtime`.

For crash verification, do not attach Xcode or LLDB. Sentry's Apple crash handling is only reliable in a normal unmanaged launch.

## Implementation Map

Key files:

- `Sources/SpliceKitSentry.m`
  Runtime Sentry bootstrap, scrubber, breadcrumbs, crash follow-up event
- `Sources/SpliceKit.m`
  Early runtime init, launch-phase tagging, legacy crash-handler fallback
- `Sources/SpliceKitServer.m`
  RPC exception capture and `last_rpc_method` tagging
- `patcher/SpliceKit/Models/PatcherSentry.swift`
  Patcher bootstrap and nonfatal reporting
- `patcher/SpliceKit/Models/PatcherModel.swift`
  Patch/update/launch error capture and runtime config propagation
- `Scripts/ensure_sentry_framework.sh`
  Downloads the pinned Sentry Apple SDK
- `Scripts/generate_sentry_config.sh`
  Generates the plist consumed by both patcher and runtime
- `release.sh`
  Uploads runtime and patcher dSYMs

## Notes

- The Sentry framework is downloaded on demand and is not checked into git.
- The runtime dSYM only became useful once the Makefile was changed to build persistent object files before linking. If you remove that object-file step, symbol upload quality will regress.
- The existing SpliceKit log files still matter. The runtime and patcher both send a log tail from the previous run when they detect a crash on startup.
