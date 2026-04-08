--[[
  Social Media Toolkit
  ────────────────────
  Prepares a timeline for social media export in multiple formats:
  - Instagram Reels (9:16 vertical, 60s max)
  - TikTok (9:16, 3min max)
  - YouTube Shorts (9:16, 60s max)
  - Twitter/X (16:9, 2min20s max)
  - Square (1:1, for feed posts)

  For each format:
  1. Analyzes duration against platform limits
  2. Generates captions with platform-appropriate style & grouping
  3. Optionally trims to max duration
  4. Exports

  HOW TO USE:
    dofile("examples/social_media_toolkit.lua")

    -- Check which platforms your timeline is ready for:
    social.analyze()

    -- Generate captions styled for TikTok:
    social.caption("tiktok")

    -- Trim timeline to Instagram Reels limit (60s):
    social.trim_to("reels")

    -- Full prepare workflow (analyze + caption + report):
    social.prepare("shorts")

  PATTERNS USED:
    - Data-driven format definitions: each platform is a table of
      constraints (max_duration, caption_style, grouping mode).
      Adding a new platform is just adding a table entry.
    - sk.rpc("captions.setStyle", {...}) + sk.rpc("captions.setGrouping",
      {...}) + sk.rpc("captions.generate", {...}) -- the caption pipeline
    - Module pattern with _G registration for REPL access
    - social.formats as a declarative config that drives all behavior

  Inspired by CommandPost's batch export and share destination workflows.
]]

local u = require("skutil")

local social = {}

-- Format definitions
social.formats = {
    reels = {
        name = "Instagram Reels",
        max_duration = 60,
        caption_style = "social_reels",
        caption_position = "bottom",
        grouping = "social",
    },
    tiktok = {
        name = "TikTok",
        max_duration = 180,
        caption_style = "bold_pop",
        caption_position = "center",
        grouping = "social",
    },
    shorts = {
        name = "YouTube Shorts",
        max_duration = 60,
        caption_style = "clean_minimal",
        caption_position = "bottom",
        grouping = "words",
        max_words = 5,
    },
    twitter = {
        name = "Twitter/X",
        max_duration = 140,
        caption_style = "subtitle_pro",
        caption_position = "bottom",
        grouping = "sentence",
    },
    square = {
        name = "Square",
        max_duration = 60,
        caption_style = "social_bold",
        caption_position = "bottom",
        grouping = "social",
    },
}

-----------------------------------------------------------
-- Analyze current timeline for social media readiness.
-- Compares the timeline duration against each platform's
-- max_duration and reports which ones are ready.
-----------------------------------------------------------
function social.analyze()
    local pos = sk.position()
    local duration = u.seconds(pos.duration)
    local state = sk.clips()
    local items = state.items or {}

    print("═══ Social Media Analysis ═══")
    print(string.format("  Duration: %.1fs (%.0f min %.0f sec)",
        duration, math.floor(duration / 60), duration % 60))
    print(string.format("  Clips:    %d", #items))
    print("")

    for id, fmt in pairs(social.formats) do
        local ok = duration <= fmt.max_duration
        local status = ok and "✓" or "⚠"
        local note = ""
        if not ok then
            note = string.format(" (%.0fs over, needs trim)", duration - fmt.max_duration)
        end
        print(string.format("  %s %-18s  max %3ds  %s%s",
            status, fmt.name, fmt.max_duration, ok and "READY" or "TOO LONG", note))
    end
    print("═════════════════════════════")
end

-----------------------------------------------------------
-- Generate captions for a specific format.
-- @param format_id  string  One of: "reels", "tiktok", "shorts", "twitter", "square"
-----------------------------------------------------------
function social.caption(format_id)
    local fmt = social.formats[format_id]
    if not fmt then
        print("Unknown format: " .. tostring(format_id))
        print("Available: " .. table.concat({"reels", "tiktok", "shorts", "twitter", "square"}, ", "))
        return
    end

    sk.log("[Social] Generating captions for " .. fmt.name .. "...")

    -- Set caption style
    local style_params = {
        preset_id = fmt.caption_style,
        position = fmt.caption_position,
    }
    sk.rpc("captions.setStyle", style_params)

    -- Set grouping
    local group_params = {mode = fmt.grouping}
    if fmt.max_words then
        group_params.max_words = fmt.max_words
    end
    sk.rpc("captions.setGrouping", group_params)

    -- Generate
    sk.rpc("captions.generate", {style = fmt.caption_style})

    sk.log("[Social] Captions generated for " .. fmt.name)
end

-----------------------------------------------------------
-- Trim timeline to max duration for a format.
-- WARNING: destructive! Deletes everything past the limit.
-- @param format_id  string  One of: "reels", "tiktok", "shorts", "twitter", "square"
-----------------------------------------------------------
function social.trim_to(format_id)
    local fmt = social.formats[format_id]
    if not fmt then
        print("Unknown format: " .. format_id)
        return
    end

    local pos = sk.position()
    local duration = u.seconds(pos.duration)

    if duration <= fmt.max_duration then
        print(fmt.name .. ": already within " .. fmt.max_duration .. "s limit")
        return
    end

    -- Set range from max_duration to end and delete
    sk.rpc("timeline.setRange", {
        start_seconds = fmt.max_duration,
        end_seconds = duration
    })
    sk.timeline("selectAll")
    sk.timeline("delete")
    sk.timeline("clearRange")

    sk.log(string.format("[Social] Trimmed to %ds for %s (removed %.1fs)",
        fmt.max_duration, fmt.name, duration - fmt.max_duration))
end

-----------------------------------------------------------
-- Full prepare workflow for a format: analyze + caption + report.
-- @param format_id  string  One of: "reels", "tiktok", "shorts", "twitter", "square"
-----------------------------------------------------------
function social.prepare(format_id)
    local fmt = social.formats[format_id]
    if not fmt then
        print("Unknown format: " .. format_id)
        return
    end

    print("═══ Preparing for " .. fmt.name .. " ═══")

    -- Step 1: Analyze
    local pos = sk.position()
    local duration = u.seconds(pos.duration)
    print(string.format("  Current duration: %.1fs (limit: %ds)", duration, fmt.max_duration))

    if duration > fmt.max_duration then
        print("  ⚠ Timeline exceeds max duration — trim manually or call social.trim_to('" .. format_id .. "')")
    else
        print("  ✓ Duration OK")
    end

    -- Step 2: Generate captions
    print("  Generating captions with style '" .. fmt.caption_style .. "'...")
    social.caption(format_id)
    print("  ✓ Captions generated")

    print("═══ Ready for export ═══")
    print("  Export with: sk.rpc('share.export', {})")
end

-- Register globally
_G.social = social

print("Social media toolkit loaded. Commands:")
print("  social.analyze()           -- check timeline against all formats")
print("  social.caption('reels')    -- generate captions for format")
print("  social.trim_to('tiktok')   -- trim timeline to format max duration")
print("  social.prepare('shorts')   -- full prepare workflow")
print("")
print("Formats: reels, tiktok, shorts, twitter, square")

return social
