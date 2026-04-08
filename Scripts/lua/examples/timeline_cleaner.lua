--[[
  Timeline Cleaner
  ────────────────
  Analyzes the timeline for common issues and optionally fixes them:
  - Flash frames (clips shorter than N frames)
  - Gaps between clips
  - Missing transitions at edit points
  - Audio peaks / silence

  Run in report-only mode first, then enable fixes.

  HOW TO USE:
    -- Report only (safe, non-destructive):
    dofile("examples/timeline_cleaner.lua")

    -- To enable auto-fix, edit the script and set:
    --   REPORT_ONLY = false        -- enable deletions
    --   ADD_TRANSITIONS = true     -- add dissolves at bare edits
    -- Then re-run.

  PATTERNS USED:
    - REPORT_ONLY flag: a two-phase workflow where analysis runs first
      and destructive changes require an explicit opt-in.
    - Frame-based duration thresholds: converting frame counts to
      seconds using the timeline's actual frame rate.
    - Reverse iteration for deletion: removing flash frames from
      last to first so earlier indices stay valid.
    - Consecutive-item analysis: checking pairs of adjacent items
      to detect missing transitions between clips.

  Inspired by CommandPost's timeline analysis and clip navigation.
]]

local u = require("skutil")

-- Configuration
local MIN_CLIP_FRAMES  = 3      -- clips shorter than this are "flash frames"
local REPORT_ONLY      = true   -- set false to auto-fix issues
local ADD_TRANSITIONS  = false  -- add cross dissolve at bare edit points
local TRANSITION_NAME  = "Cross Dissolve"

-- Get timeline state
local state = sk.rpc("timeline.getDetailedState", {})
if not state or not state.items then
    sk.log("[Cleaner] No timeline data")
    return
end

local pos = sk.position()
local fps = pos.frameRate or 30
local min_duration = MIN_CLIP_FRAMES / fps

local items = state.items
local issues = {
    flash_frames = {},
    short_clips = {},
    transitions_missing = 0,
    total_clips = 0,
    total_transitions = 0,
    total_gaps = 0,
    total_duration = 0,
}

-- Analyze
for i, clip in ipairs(items) do
    local dur = u.clip_duration(clip)
    local clip_type = clip.type or clip.class or "unknown"

    if clip_type:find("Transition") then
        issues.total_transitions = issues.total_transitions + 1
    elseif clip_type:find("Gap") then
        issues.total_gaps = issues.total_gaps + 1
    else
        issues.total_clips = issues.total_clips + 1
        issues.total_duration = issues.total_duration + dur

        if dur < min_duration and dur > 0 then
            table.insert(issues.flash_frames, {
                index = i,
                name = clip.name or "unnamed",
                start = u.clip_start(clip),
                duration = dur,
                frames = math.floor(dur * fps + 0.5)
            })
        elseif dur < 1.0 then
            table.insert(issues.short_clips, {
                index = i,
                name = clip.name or "unnamed",
                start = u.clip_start(clip),
                duration = dur,
            })
        end
    end

    -- Check for missing transitions between consecutive clips
    if i > 1 and not clip_type:find("Transition") then
        local prev = items[i - 1]
        local prev_type = prev.type or ""
        if not prev_type:find("Transition") and not prev_type:find("Gap") then
            issues.transitions_missing = issues.transitions_missing + 1
        end
    end
end

-- Report
print("╔══════════════════════════════════════════╗")
print("║         TIMELINE HEALTH REPORT           ║")
print("╠══════════════════════════════════════════╣")
print(string.format("║  Total clips:       %4d                 ║", issues.total_clips))
print(string.format("║  Total transitions: %4d                 ║", issues.total_transitions))
print(string.format("║  Total gaps:        %4d                 ║", issues.total_gaps))
print(string.format("║  Total duration:    %7.1fs              ║", issues.total_duration))
print(string.format("║  Frame rate:        %5.1f fps             ║", fps))
print("╠══════════════════════════════════════════╣")

if #issues.flash_frames > 0 then
    print(string.format("║  ⚠ Flash frames:    %4d                 ║", #issues.flash_frames))
    for _, ff in ipairs(issues.flash_frames) do
        print(string.format("║    → %s at %.2fs (%d frames)  ║",
            ff.name:sub(1, 15), ff.start, ff.frames))
    end
else
    print("║  ✓ No flash frames                       ║")
end

if #issues.short_clips > 0 then
    print(string.format("║  ⚠ Short clips (<1s): %3d                ║", #issues.short_clips))
else
    print("║  ✓ No short clips                        ║")
end

if issues.transitions_missing > 0 then
    print(string.format("║  ⚠ Bare edit points: %4d                ║", issues.transitions_missing))
else
    print("║  ✓ All edits have transitions             ║")
end

print("╚══════════════════════════════════════════╝")

-- Fix issues if not in report-only mode.
-- WHY backwards: ripple-delete shifts everything after the deleted clip.
-- Deleting from the end first means the shift only affects clips we have
-- already processed.
if not REPORT_ONLY then
    -- Remove flash frames (work backwards to preserve indices)
    if #issues.flash_frames > 0 then
        sk.log("[Cleaner] Removing " .. #issues.flash_frames .. " flash frames...")
        for i = #issues.flash_frames, 1, -1 do
            local ff = issues.flash_frames[i]
            sk.seek(ff.start + 0.001)
            sk.select_clip()
            sk.timeline("delete")
        end
        sk.log("[Cleaner] Flash frames removed")
    end

    -- Add transitions at bare edit points
    if ADD_TRANSITIONS and issues.transitions_missing > 0 then
        sk.log("[Cleaner] Adding transitions...")
        sk.go_to_start()
        local added = 0
        for i = 1, issues.transitions_missing do
            sk.timeline("nextEdit")
            sk.rpc("transitions.apply", {name = TRANSITION_NAME})
            added = added + 1
        end
        sk.log("[Cleaner] Added " .. added .. " transitions")
    end
end

return issues
