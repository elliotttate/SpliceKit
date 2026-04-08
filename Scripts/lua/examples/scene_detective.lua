--[[
  Scene Detective
  ───────────────
  Detects scene changes in the timeline, captures a thumbnail from
  each scene, and generates a scene-by-scene report with timing,
  duration, and optional markers/chapter markers.

  Useful for:
  - Creating chapter markers for YouTube
  - Building a visual storyboard
  - Identifying pacing issues
  - Finding the longest/shortest scenes

  HOW TO USE:
    dofile("examples/scene_detective.lua")

    Tweak THRESHOLD for sensitivity:
      0.1 = very sensitive (detects subtle changes)
      0.5 = moderate (only clear scene cuts)
      0.8 = insensitive (only dramatic visual changes)

    Set CHAPTER_MARKERS = true to create YouTube-compatible chapters.
    Set CAPTURE_THUMBS  = false to skip screenshot capture (faster).

  PATTERNS USED:
    - sk.rpc("scene.detect", {...}) -- frame-comparison scene detection
      that returns a list of timestamps where visual content changes
    - Building a derived "scenes" list from raw cut timestamps by
      computing durations between consecutive cuts
    - sk.rpc("viewer.capture", {path=...}) to screenshot the viewer at
      each scene's midpoint (representative frame)
    - sk.eval() for ObjC one-liners (creating directories via NSFileManager)
    - Statistical summary (longest, shortest, average scene length)
    - u.timecode() for human-readable HH:MM:SS:FF formatting

  Inspired by CommandPost's scene detection and marker management.
]]

-- Configuration
local THRESHOLD        = 0.3    -- scene detection sensitivity (0-1, lower = more sensitive)
local SAMPLE_INTERVAL  = 0.1    -- how often to sample frames (seconds)
local ADD_MARKERS      = true   -- add markers at scene boundaries
local CHAPTER_MARKERS  = false  -- use chapter markers instead of standard
local CAPTURE_THUMBS   = true   -- capture viewer screenshot at each scene
local THUMB_DIR        = os.tmpname():match("(.+)/") .. "/scene_thumbs"
local MIN_SCENE_LENGTH = 0.5    -- ignore scenes shorter than this

local u = require("skutil")

-----------------------------------------------------------
-- Step 1: Detect scene changes
-----------------------------------------------------------
sk.log("[SceneDetective] Analyzing timeline for scene changes...")
sk.log("[SceneDetective] Threshold: " .. THRESHOLD .. ", interval: " .. SAMPLE_INTERVAL)

local detection = sk.rpc("scene.detect", {
    threshold = THRESHOLD,
    sample_interval = SAMPLE_INTERVAL
})

if not detection or not detection.timestamps then
    sk.log("[SceneDetective] Scene detection failed or no scenes found")
    return
end

local timestamps = detection.timestamps
sk.log("[SceneDetective] Found " .. #timestamps .. " scene changes")

-----------------------------------------------------------
-- Step 2: Build scene list with durations
-- scene.detect returns CUT timestamps, but we want SCENES
-- (regions between cuts). So scene[1] = 0..first_cut,
-- scene[2] = first_cut..second_cut, etc.
-----------------------------------------------------------
local pos = sk.position()
local total_duration = u.seconds(pos.duration)

local scenes = {}
local prev_time = 0

for i, t in ipairs(timestamps) do
    local duration = t - prev_time
    -- Filter out very short scenes (often false positives from
    -- flash frames or transition effects)
    if duration >= MIN_SCENE_LENGTH then
        table.insert(scenes, {
            number = #scenes + 1,
            start = prev_time,
            ending = t,
            duration = duration,
        })
    end
    prev_time = t
end

-- Last scene: from the final cut to the end of the timeline
if total_duration - prev_time >= MIN_SCENE_LENGTH then
    table.insert(scenes, {
        number = #scenes + 1,
        start = prev_time,
        ending = total_duration,
        duration = total_duration - prev_time,
    })
end

-----------------------------------------------------------
-- Step 3: Add markers
-----------------------------------------------------------
if ADD_MARKERS then
    local marker_times = {}
    for _, scene in ipairs(scenes) do
        table.insert(marker_times, scene.start)
    end

    if CHAPTER_MARKERS then
        -- Add chapter markers (need to go to each position)
        for _, scene in ipairs(scenes) do
            sk.seek(scene.start)
            sk.timeline("addChapterMarker")
        end
        sk.log("[SceneDetective] Added " .. #scenes .. " chapter markers")
    else
        sk.rpc("timeline.addMarkers", {times = marker_times})
        sk.log("[SceneDetective] Added " .. #scenes .. " markers")
    end
end

-----------------------------------------------------------
-- Step 4: Capture thumbnails
-----------------------------------------------------------
if CAPTURE_THUMBS then
    -- Create thumbnail directory
    sk.eval("[[NSFileManager defaultManager] createDirectoryAtPath:@'" ..
            THUMB_DIR .. "' withIntermediateDirectories:YES attributes:nil error:nil]")

    for _, scene in ipairs(scenes) do
        -- Seek to middle of scene for representative frame
        local mid = scene.start + (scene.duration / 2)
        sk.seek(mid)
        sk.sleep(0.2)  -- let viewer update

        local thumb_path = string.format("%s/scene_%03d.png", THUMB_DIR, scene.number)
        sk.rpc("viewer.capture", {path = thumb_path})
        scene.thumbnail = thumb_path
    end
    sk.log("[SceneDetective] Captured " .. #scenes .. " thumbnails to " .. THUMB_DIR)
end

-----------------------------------------------------------
-- Step 5: Generate report
-----------------------------------------------------------
local function format_tc(seconds)
    return u.timecode(seconds, pos.frameRate or 30)
end

-- Find longest and shortest
local longest = {duration = 0}
local shortest = {duration = math.huge}
local avg_duration = 0

for _, scene in ipairs(scenes) do
    avg_duration = avg_duration + scene.duration
    if scene.duration > longest.duration then longest = scene end
    if scene.duration < shortest.duration then shortest = scene end
end
avg_duration = #scenes > 0 and (avg_duration / #scenes) or 0

print("")
print("╔════════════════════════════════════════════════════════════╗")
print("║                    SCENE DETECTIVE REPORT                  ║")
print("╠════════════════════════════════════════════════════════════╣")
print(string.format("║  Total scenes:     %4d                                    ║", #scenes))
print(string.format("║  Total duration:   %s (%6.1fs)                  ║",
    format_tc(total_duration), total_duration))
print(string.format("║  Average scene:    %6.1fs                                ║", avg_duration))
print(string.format("║  Longest scene:    #%-3d  %6.1fs (at %s)       ║",
    longest.number or 0, longest.duration, format_tc(longest.start or 0)))
print(string.format("║  Shortest scene:   #%-3d  %6.1fs (at %s)       ║",
    shortest.number or 0, shortest.duration, format_tc(shortest.start or 0)))
print("╠════════════════════════════════════════════════════════════╣")
print("║  #    Start         End           Duration                ║")
print("╠════════════════════════════════════════════════════════════╣")

for _, scene in ipairs(scenes) do
    local bar_len = math.floor(scene.duration / total_duration * 20)
    local bar = string.rep("█", math.max(1, bar_len))
    print(string.format("║  %-3d  %s  %s  %5.1fs  %-20s ║",
        scene.number,
        format_tc(scene.start),
        format_tc(scene.ending),
        scene.duration,
        bar))
end

print("╚════════════════════════════════════════════════════════════╝")

if CAPTURE_THUMBS then
    print("\nThumbnails saved to: " .. THUMB_DIR)
end

-- Return data for programmatic use
return {
    scenes = scenes,
    total_duration = total_duration,
    average_duration = avg_duration,
    longest = longest,
    shortest = shortest,
    thumb_dir = CAPTURE_THUMBS and THUMB_DIR or nil,
}
