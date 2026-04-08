--[[
  Debug Timeline Inspector
  ────────────────────────
  Deep-inspects the timeline data model, revealing FCP's internal
  representation. Shows hidden gaps, lane structure, effect stacks,
  and the ObjC class hierarchy behind each clip.

  Useful for:
  - Understanding FCP's internal data model
  - Debugging SpliceKit scripts
  - Finding the right ObjC classes for new features
  - Discovering hidden timeline items

  HOW TO USE:
    dofile("examples/debug_timeline_inspector.lua")

    -- Then use these global functions from the REPL:
    inspect()            -- deep inspect the clip at playhead
    dump_tl()            -- full timeline structure by lane
    explore()            -- ObjC class hierarchy exploration
    perf()               -- performance snapshot (fps, threads, memory)
    debug_visuals(true)  -- enable FCP's internal debug overlays
    debug_visuals(false) -- disable debug overlays

  PATTERNS USED:
    - sk.rpc("debug.enablePreset", {...}) to toggle FCP's built-in
      TLK debug overlays (lane indices, misaligned edges, hidden items)
    - sk.rpc("inspector.get", {section=...}) to read transform, crop,
      compositing, and distort properties from the selected clip
    - sk.rpc("effects.getClipEffects", {}) to enumerate effects applied
      to the selected clip
    - sk.eval() for arbitrary ObjC expression evaluation (like lldb's po)
    - sk.rpc("system.getSuperchain", {...}) to walk the ObjC inheritance
      chain of any class
    - Grouping timeline items by lane number to visualize the timeline
      structure (primary storyline vs connected clips above/below)
    - Registering multiple global functions for REPL convenience

  Inspired by CommandPost's debug console and FCP introspection tools.
]]

local u = require("skutil")

-----------------------------------------------------------
-- Enable debug overlays for visual inspection
-----------------------------------------------------------
local function enable_debug_visuals(on)
    if on then
        sk.rpc("debug.enablePreset", {preset = "timeline_visual"})
        print("Debug visuals ON — lane indices, misaligned edges, hidden items visible")
    else
        sk.rpc("debug.enablePreset", {preset = "all_off"})
        print("Debug visuals OFF")
    end
end

-----------------------------------------------------------
-- Deep inspect a single clip at playhead.
-- Selects the clip, dumps its metadata, then queries the
-- inspector for transform/compositing/crop/distort values
-- and lists any applied effects.
-----------------------------------------------------------
local function inspect_clip()
    sk.select_clip()
    local sel = sk.selected()

    print("\n=== CLIP INSPECTOR ===")

    -- Basic info from selection (flat key-value pairs only)
    if sel and type(sel) == "table" then
        for k, v in pairs(sel) do
            if type(v) ~= "table" then
                print(string.format("  %-20s = %s", tostring(k), tostring(v)))
            end
        end
    end

    -- Query each inspector section for the selected clip's properties.
    -- inspector.get reads the live values without needing the Inspector
    -- panel to be visible in the UI.
    local sections = {"transform", "compositing", "crop", "distort"}
    for _, section in ipairs(sections) do
        local props = sk.rpc("inspector.get", {section = section})
        if props and type(props) == "table" then
            local has_data = false
            for k, v in pairs(props) do
                if k ~= "error" then has_data = true; break end
            end
            if has_data then
                print(string.format("\n  [%s]", section))
                for k, v in pairs(props) do
                    if type(v) ~= "table" then
                        print(string.format("    %-16s = %s", tostring(k), tostring(v)))
                    end
                end
            end
        end
    end

    -- Effects on this clip
    local effects = sk.rpc("effects.getClipEffects", {})
    if effects and effects.effects then
        print("\n  [effects]")
        for i, fx in ipairs(effects.effects) do
            print(string.format("    %d. %s (%s)",
                i, fx.name or "?", fx.effectID or "?"))
        end
    end

    print("═══════════════════════")
end

-----------------------------------------------------------
-- Dump full timeline structure.
-- Groups items by lane so you can see the primary storyline
-- (lane 0), connected clips above (lane 1, 2, ...), and
-- connected clips below (lane -1, -2, ...).
-----------------------------------------------------------
local function dump_timeline()
    local state = sk.rpc("timeline.getDetailedState", {})
    if not state or not state.items then
        print("No timeline data")
        return
    end

    local pos = sk.position()
    local items = state.items

    print("\n╔══════════════════════════════════════════════════════════════╗")
    print("║                  TIMELINE STRUCTURE DUMP                     ║")
    print("╠══════════════════════════════════════════════════════════════╣")
    print(string.format("║  Sequence:    %s", state.sequence or "?"))
    local total_dur = u.timeline_duration()
    print(string.format("║  Items:       %d", #items))
    print(string.format("║  Duration:    %.2fs", total_dur))
    print(string.format("║  Frame rate:  %.1f fps", pos.frameRate or 0))
    print(string.format("║  Playhead:    %.2fs", pos.seconds or 0))
    print("╠══════════════════════════════════════════════════════════════╣")

    -- Group by lane
    local lanes = {}
    for _, item in ipairs(items) do
        local lane = item.lane or 0
        if not lanes[lane] then lanes[lane] = {} end
        table.insert(lanes[lane], item)
    end

    -- Sort lane numbers
    local lane_nums = {}
    for lane in pairs(lanes) do
        table.insert(lane_nums, lane)
    end
    table.sort(lane_nums)

    for _, lane in ipairs(lane_nums) do
        local lane_items = lanes[lane]
        local lane_label = lane == 0 and "PRIMARY STORYLINE" or
                           (lane > 0 and "CONNECTED (above +" .. lane .. ")" or
                            "CONNECTED (below " .. lane .. ")")

        print(string.format("║                                                              ║"))
        print(string.format("║  ── Lane %d: %s ──", lane, lane_label))

        for _, item in ipairs(lane_items) do
            local name = (item.name or ""):sub(1, 25)
            local item_type = item.type or item.class or "?"
            local start_t = u.clip_start(item)
            local dur = u.clip_duration(item)
            local end_t = u.clip_end(item)

            -- Type icon
            local icon = "📎"
            if item_type:find("Transition") then icon = "⟷"
            elseif item_type:find("Gap") then icon = "░░"
            elseif item_type:find("Title") then icon = "Tt"
            elseif item_type:find("Audio") then icon = "♪"
            elseif item_type:find("Generator") then icon = "◆"
            end

            print(string.format("║    %s %-25s  %6.2f → %6.2f (%5.2fs)  %s",
                icon, name, start_t, end_t, dur,
                item_type:sub(1, 20)))

            -- Show effects if present
            if item.effects and type(item.effects) == "table" then
                for _, fx in ipairs(item.effects) do
                    print(string.format("║       ├─ fx: %s", fx.name or fx.effectID or "?"))
                end
            end
        end
    end

    print("╚══════════════════════════════════════════════════════════════╝")
end

-----------------------------------------------------------
-- ObjC class hierarchy exploration
-----------------------------------------------------------
local function explore_clip_class()
    -- Get the sequence and inspect its class hierarchy
    local r = sk.eval("NSApp.delegate.activeEditorContainer")
    if r and r.class then
        print("\n═══ Editor Container ═══")
        print("  Class: " .. (r.class or "?"))

        local chain = sk.rpc("system.getSuperchain", {className = r.class})
        if chain and chain.chain then
            print("  Hierarchy: " .. table.concat(chain.chain, " → "))
        end
    end

    -- Get timeline module info
    local classes = sk.rpc("system.getClasses", {filter = "FFAnchoredTimeline"})
    if classes and classes.classes then
        print("\n═══ Timeline Classes ═══")
        for _, cls in ipairs(classes.classes) do
            print("  " .. cls)
        end
    end
end

-----------------------------------------------------------
-- Performance analysis.
-- Uses FCP's built-in HMDFramerate monitor (ProCore), the Mach
-- kernel thread APIs, and Lua VM memory stats. Check Console.app
-- or `log stream --process "Final Cut Pro"` for fps data.
-----------------------------------------------------------
local function perf_check()
    print("\n═══ Performance Check ═══")

    -- Start framerate monitor briefly
    sk.rpc("debug.startFramerateMonitor", {interval = 1.0})
    sk.sleep(3)
    sk.rpc("debug.stopFramerateMonitor")

    -- Thread info
    local threads = sk.rpc("debug.threads", {})
    if threads then
        print(string.format("  Threads: %s", threads.count or "?"))
    end

    -- Memory
    local lua_state = sk.rpc("lua.getState", {})
    if lua_state then
        print(string.format("  Lua memory: %d KB / %d MB limit",
            lua_state.memory_kb or 0, lua_state.memory_limit_mb or 0))
    end

    print("  (Check Console.app for framerate data)")
    print("═════════════════════════")
end

-----------------------------------------------------------
-- Register functions globally
-----------------------------------------------------------
_G.inspect = inspect_clip
_G.dump_tl = dump_timeline
_G.explore = explore_clip_class
_G.perf = perf_check
_G.debug_visuals = enable_debug_visuals

print("Debug Inspector loaded. Commands:")
print("  inspect()            -- deep inspect clip at playhead")
print("  dump_tl()            -- full timeline structure dump")
print("  explore()            -- ObjC class hierarchy")
print("  perf()               -- performance snapshot")
print("  debug_visuals(true)  -- enable visual debug overlays")
print("  debug_visuals(false) -- disable debug overlays")
