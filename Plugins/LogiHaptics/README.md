# FCP Haptics — MX Master 4 bridge

Mirrors the four built-in Final Cut Pro haptics off the Force Touch trackpad
onto the **Logitech MX Master 4** mouse.

## Architecture

```
┌──────────────────────────┐    JSON-RPC notification     ┌────────────────────────┐
│  FCP + SpliceKit dylib   │ ──── 127.0.0.1:9876 ───────► │  LogiPluginService     │
│  HapticBridge swizzle    │                              │  + FCPHaptics plugin   │
└──────────────────────────┘                              └─────────┬──────────────┘
                                                                    │ RaiseEvent("…")
                                                                    ▼
                                                              ┌──────────────┐
                                                              │ MX Master 4  │
                                                              └──────────────┘
```

- **SpliceKit** (in `Sources/SpliceKitHapticBridge.m`) swizzles
  `-[NSHapticFeedbackPerformer performFeedbackPattern:performanceTime:]`,
  walks the call stack with `backtrace(3)` to identify which FCP function
  triggered the haptic, and broadcasts a typed event:
  ```json
  {"jsonrpc":"2.0","method":"event",
   "params":{"type":"haptic","name":"viewer_snap",
             "pattern":1,"performance_time":1,
             "caller_symbol":"___67-[FFSnapGridOSC addDrawProperties_…]_block_invoke"}}
  ```
- **FCPHaptics** (a C#/.NET 10 Logi Actions SDK plugin in
  `FCPHapticsPlugin/`) opens a TCP connection to SpliceKit, subscribes to
  the `haptic` event stream, parses each notification, and calls
  `PluginEvents.RaiseEvent(name)`. Logi Options+ then routes the event
  through `events/extra/eventMapping.yaml` to a hardware waveform on the
  MX Master 4.

## Event ↔ waveform mapping

| Event               | Trigger in FCP                                    | Waveform on MX Master 4 |
|---------------------|---------------------------------------------------|-------------------------|
| `viewer_snap`       | Viewer canvas snap line crossed during a drag     | `subtle_collision`      |
| `title_drop_snap`   | Title drag-into-timeline highlight changes        | `damp_collision`        |
| `trim_limit`        | Trim/roll edge first hits a constraint            | `sharp_collision`       |
| `jkl_pressure`      | FF/RW transport button steps to a new rate        | `sharp_state_change`    |
| `unknown`           | FCP fired a haptic from an unrecognised site      | `subtle_collision`      |

Edit `FCPHapticsPlugin/src/package/events/extra/eventMapping.yaml` to taste,
then rebuild — Logi Options+ hot-reloads the mapping.

## Build

```bash
cd Plugins/LogiHaptics/FCPHapticsPlugin
dotnet build src/FCPHapticsPlugin.csproj -c Release
```

The current Logi Plugin Service 6.4 SDK targets .NET 10, so the .NET 10 SDK
must be installed and selected by `dotnet` before building.

The build target writes a `.link` file pointing at
`bin/Release/` into `~/Library/Application Support/Logi/LogiPluginService/Plugins/`,
then `open loupedeck:plugin/FCPHaptics/reload`s the running service so the
plugin shows up live without restarting Logi Options+.

The matching SpliceKit changes ship in the main `make deploy` build (the
swizzle module is `Sources/SpliceKitHapticBridge.m`, registered through
`SOURCES.txt` and installed from `appDidLaunch` in `SpliceKit.m`).

## Testing

1. **Confirm hardware/system prerequisites.**
   - MX Master 4 paired and visible in Logi Options+.
   - Force Touch trackpad available (built-in MBP, Magic Trackpad 2+, etc.).
     Without one, FCP itself never reaches the haptic call path because
     `+[NSHapticFeedbackManager defaultPerformer]` returns `nil`.
   - System Settings → Trackpad → "Force Click and haptic feedback" ON.

2. **Restart FCP** so the new SpliceKit dylib (with the haptic bridge) loads.
   The connecting plugin will reconnect automatically within a few seconds.

3. **Verify the SpliceKit side installed.** Tail the SpliceKit log and look
   for the install line:
   ```bash
   tail -f ~/Library/Logs/SpliceKit/splicekit.log | grep HapticBridge
   ```
   Expected:
   ```
   [HapticBridge] swizzled <…performer class…> -performFeedbackPattern:performanceTime:
   [HapticBridge] installed: 1 performer class(es) swizzled — subscribe to type='haptic' over JSON-RPC to receive events
   ```

4. **Verify the Logi side connected.** Tail the plugin log:
   ```bash
   tail -f "$HOME/Library/Application Support/Logi/LogiPluginService/Logs/plugin_logs/FCPHaptics.log"
   ```
   Expected on plugin load and after each successful (re)connect:
   ```
   FCPHaptics loaded — bridging SpliceKit 127.0.0.1:9876 -> haptic events.
   Subscribed to SpliceKit haptic event stream.
   ```

5. **Trigger each of the four haptics in FCP** and confirm both:
   (a) a line appears in the SpliceKit log
       (`[HapticBridge] haptic 'viewer_snap' …`), and
   (b) the MX Master 4 fires the configured waveform.

   | Haptic            | How to fire                                                                                                |
   |-------------------|------------------------------------------------------------------------------------------------------------|
   | `viewer_snap`     | Open a project with a title or transform-effected clip, then drag a corner handle across a snap guide.     |
   | `title_drop_snap` | Drag a title from the Titles browser onto the timeline; the "drop highlight" snapping to clip edges fires. |
   | `trim_limit`      | Trim a clip's edge inward until you run out of media handles — the "wall" hit is the haptic.               |
   | `jkl_pressure`    | Press and **hold** the FF or RW arrow under the viewer, then push harder. Each rate-bucket step fires.     |

6. **Optional: live-tap the JSON-RPC stream** with `nc` to see the raw
   broadcast — useful if a haptic isn't reaching the plugin:
   ```bash
   ( printf '{"jsonrpc":"2.0","id":1,"method":"events.subscribe","params":{"patterns":["haptic"]}}\n'; \
     cat ) | nc 127.0.0.1 9876
   ```
   Each FCP haptic should print one notification line, e.g.:
   ```
   {"jsonrpc":"2.0","method":"event","params":{"type":"haptic","name":"viewer_snap","pattern":1,"performance_time":1,"caller_symbol":"…"}}
   ```

## Troubleshooting

- **No haptics on the mouse.** Confirm the plugin reloaded after the build:
  the `FCPHaptics.log` should show "Plugin 'FCPHaptics' version '0.1' loaded".
  If absent, kick it with
  `open "loupedeck:plugin/FCPHaptics/reload"` from a terminal.
- **`Subscribed` line never appears.** SpliceKit isn't accepting connections.
  Check `bridge_status` via the SpliceKit MCP, or `lsof -nP -i:9876`.
- **`unknown` haptic on every event.** Symbol classification missed because
  Apple stripped or renamed an FCP method. Inspect the `caller_symbol`
  field in the event payload and add a new branch to
  `SK_haptic_classifyCallerSymbol` in `SpliceKitHapticBridge.m`.
- **Trackpad still clicks but mouse stays silent.** Confirm
  `HasHapticMapping` is in the plugin's `LoupedeckPackage.yaml` capabilities
  list — without it, Logi Options+ ignores the YAML mapping entirely.

## Extending

Adding a new FCP haptic event takes four edits:

1. **`SpliceKitHapticBridge.m`** → add a `[sym containsString:…]` case in
   `SK_haptic_classifyCallerSymbol` returning your new event name.
2. **`FCPHapticsPlugin.cs`** → append the name to `KnownEvents` and an
   `AddEvent(...)` line in `Load()`.
3. **`events/DefaultEventSource.yaml`** → append a new `name`/`displayName`/
   `description` block.
4. **`events/extra/eventMapping.yaml`** → map the new event to a waveform.

Rebuild SpliceKit (`make deploy && restart FCP`), rebuild the plugin
(`dotnet build`), retest.
