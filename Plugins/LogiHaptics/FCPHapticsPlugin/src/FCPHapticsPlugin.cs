namespace Loupedeck.FCPHapticsPlugin
{
    using System;
    using System.IO;
    using System.Net.Sockets;
    using System.Text;
    using System.Text.Json;
    using System.Threading;

    // FCPHaptics — bridge between SpliceKit (in Final Cut Pro) and Logi Options+.
    //
    // SpliceKit injects into FCP and exposes a JSON-RPC server on TCP 127.0.0.1:9876.
    // Its haptic-bridge swizzle observes every NSHapticFeedbackPerformer call and
    // broadcasts JSON-RPC notifications shaped like:
    //
    //   {"jsonrpc":"2.0","method":"event",
    //    "params":{"type":"haptic","name":"viewer_snap",
    //              "pattern":1,"performance_time":1,"caller_symbol":"…"}}
    //
    // This plugin maintains a persistent connection, subscribes to the "haptic"
    // event stream, and translates each notification into a PluginEvents.RaiseEvent
    // call. Logi Options+ then routes the event to whatever waveform the user has
    // mapped in src/package/events/extra/eventMapping.yaml — and the MX Master 4
    // delivers the corresponding tactile feedback.

    public class FCPHapticsPlugin : Plugin
    {
        // Universal plugin — tactile feedback only, no UI actions and no app binding.
        public override Boolean UsesApplicationApiOnly => true;
        public override Boolean HasNoApplication => true;

        // Match the symbolic event names emitted by SpliceKitHapticBridge.m.
        // Adding a new haptic site over there means: (a) add the symbol match
        // there, (b) declare it in DefaultEventSource.yaml, (c) map it in
        // eventMapping.yaml, (d) optionally tweak this set if you want to
        // suppress it before raising.
        private static readonly String[] KnownEvents = new[]
        {
            // Native FCP haptics observed via the AppKit performer swizzle.
            "viewer_snap",
            "title_drop_snap",
            "trim_limit",
            "jkl_pressure",

            // SpliceKit-added snap haptics (snappingCalc:… delegate hook).
            "clip_snap",
            "playhead_snap",

            "unknown",
        };

        private const String SpliceKitHost = "127.0.0.1";
        private const Int32 SpliceKitPort = 9876;
        private const Int32 ReconnectDelayMs = 3000;

        private CancellationTokenSource _cts;
        private Thread _bridgeThread;

        public FCPHapticsPlugin()
        {
            PluginLog.Init(this.Log);
            PluginResources.Init(this.Assembly);
        }

        public override void Load()
        {
            // Register every event up front. Logi Options+ will only fire haptics
            // for events that are both declared here AND mapped in
            // events/extra/eventMapping.yaml. Declarations are idempotent — a
            // duplicate AddEvent silently no-ops.
            // Native FCP haptics — observed via the AppKit performer swizzle.
            this.PluginEvents.AddEvent("viewer_snap",
                "Viewer Snap",
                "Viewer canvas snap line crossed (transform/crop/title handle).");
            this.PluginEvents.AddEvent("title_drop_snap",
                "Title Drop Snap",
                "Title drag-into-timeline highlight snapped to a new alignment.");
            this.PluginEvents.AddEvent("trim_limit",
                "Trim Limit",
                "Trim or roll edge first hits a constraint (out of media handles).");
            this.PluginEvents.AddEvent("jkl_pressure",
                "J/K/L Pressure Step",
                "Force Touch transport button stepped to a new playback rate bucket.");

            // SpliceKit-added snap haptics — covers FCP's snap surface that
            // wasn't natively haptic'd (clip-body snap, playhead snap, etc.).
            this.PluginEvents.AddEvent("clip_snap",
                "Clip Snap",
                "A clip dragged on the timeline snapped to an edit point, marker, or other target.");
            this.PluginEvents.AddEvent("playhead_snap",
                "Playhead Snap",
                "The playhead (or skim playhead) snapped to a clip edge, marker, or range edge.");

            // Catch-all for unrecognised classifications.
            this.PluginEvents.AddEvent("unknown",
                "Unknown FCP Haptic",
                "FCP fired a haptic from an unrecognised call site — useful for discovery.");

            this._cts = new CancellationTokenSource();
            this._bridgeThread = new Thread(() => this.BridgeLoop(this._cts.Token))
            {
                IsBackground = true,
                Name = "FCPHaptics-Bridge",
            };
            this._bridgeThread.Start();

            PluginLog.Info($"FCPHaptics loaded — bridging SpliceKit {SpliceKitHost}:{SpliceKitPort} -> haptic events.");
        }

        public override void Unload()
        {
            this._cts?.Cancel();
            // Don't Join — connection read may be blocked in Socket I/O for a
            // few seconds after the cancel; let it die when the process unloads.
            this._cts = null;
            this._bridgeThread = null;
        }

        // Persistent connection loop. Connects, subscribes, reads NDJSON until
        // the socket closes or an error occurs, then sleeps before reconnecting.
        // The plugin keeps running across SpliceKit restarts (FCP relaunches).
        private void BridgeLoop(CancellationToken token)
        {
            while (!token.IsCancellationRequested)
            {
                try
                {
                    this.RunOneConnection(token);
                }
                catch (OperationCanceledException)
                {
                    return;
                }
                catch (Exception ex)
                {
                    PluginLog.Warning($"Bridge connection error: {ex.GetType().Name}: {ex.Message}");
                }

                if (token.IsCancellationRequested) return;
                try
                {
                    Thread.Sleep(ReconnectDelayMs);
                }
                catch (ThreadInterruptedException)
                {
                    return;
                }
            }
        }

        private void RunOneConnection(CancellationToken token)
        {
            using var client = new TcpClient();
            // BeginConnect-style with manual cancellation so we don't hang an
            // unloading plugin on a dead host.
            var connectTask = client.ConnectAsync(SpliceKitHost, SpliceKitPort);
            if (!connectTask.Wait(2000, token))
            {
                throw new TimeoutException($"Couldn't connect to SpliceKit at {SpliceKitHost}:{SpliceKitPort} within 2s.");
            }
            connectTask.GetAwaiter().GetResult();

            client.NoDelay = true;
            using var stream = client.GetStream();
            using var reader = new StreamReader(stream, new UTF8Encoding(false));

            // Subscribe to the haptic event stream. SpliceKit's events.subscribe
            // installs a per-connection allowlist; without it we'd receive zero
            // notifications even though they're being broadcast.
            var subscribeRequest = JsonSerializer.Serialize(new
            {
                jsonrpc = "2.0",
                id = 1,
                method = "events.subscribe",
                @params = new { patterns = new[] { "haptic" } }
            });
            var subscribeBytes = Encoding.UTF8.GetBytes(subscribeRequest + "\n");
            stream.Write(subscribeBytes, 0, subscribeBytes.Length);
            PluginLog.Info("Subscribed to SpliceKit haptic event stream.");

            String line;
            while (!token.IsCancellationRequested && (line = reader.ReadLine()) != null)
            {
                this.HandleLine(line);
            }
        }

        private void HandleLine(String line)
        {
            if (String.IsNullOrWhiteSpace(line)) return;

            JsonDocument doc;
            try
            {
                doc = JsonDocument.Parse(line);
            }
            catch (JsonException)
            {
                // Don't dump the whole line in logs — caller_symbol can include
                // mangled FCP method names that confuse downstream tooling.
                PluginLog.Warning($"Skipping malformed JSON-RPC frame ({line.Length} chars).");
                return;
            }

            using (doc)
            {
                if (!doc.RootElement.TryGetProperty("method", out var methodEl)) return;
                if (methodEl.GetString() != "event") return;
                if (!doc.RootElement.TryGetProperty("params", out var paramsEl)) return;
                if (paramsEl.ValueKind != JsonValueKind.Object) return;
                if (!paramsEl.TryGetProperty("type", out var typeEl)) return;
                if (typeEl.GetString() != "haptic") return;

                var name = paramsEl.TryGetProperty("name", out var nameEl)
                    ? nameEl.GetString() : "unknown";
                if (String.IsNullOrEmpty(name)) name = "unknown";

                if (Array.IndexOf(KnownEvents, name) < 0)
                {
                    // Unknown name — Logi Options+ will silently drop it without
                    // a YAML mapping, so coerce to the catch-all event.
                    PluginLog.Info($"Mapping unrecognised haptic name '{name}' to 'unknown'.");
                    name = "unknown";
                }

                try
                {
                    this.PluginEvents.RaiseEvent(name);
                }
                catch (Exception ex)
                {
                    PluginLog.Warning($"RaiseEvent('{name}') failed: {ex.Message}");
                }
            }
        }
    }
}
