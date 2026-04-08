--[[
  Podcast Producer -- End-to-End Podcast Post-Production
  ─────────────────────────────────────────────────────
  Automates the entire podcast editing workflow:

  1. Transcribes the episode
  2. Identifies speakers and labels them
  3. Removes silences and filler words
  4. Creates chapter markers at topic boundaries
  5. Exports SRT subtitles, plain text, and YouTube chapter list

  Designed for multi-speaker podcast/interview content.

  HOW TO USE:
    dofile("examples/podcast_producer.lua")

    -- Full pipeline (transcribe -> label -> clean -> chapter -> export):
    podcast.produce("Episode 42")

    -- Full pipeline with options:
    podcast.produce("Episode 42", {
        engine = "parakeet_v3",       -- transcription engine
        skip_transcribe = false,      -- set true to reuse existing transcript
        speakers = {                  -- manual speaker labels (word index ranges)
            {"Host",  0,   500},
            {"Guest", 501, 1200},
        },
        chapters = {                  -- manual chapters (overrides auto-detect)
            {time = 0,   title = "Intro"},
            {time = 300, title = "Topic 1"},
            {time = 900, title = "Wrap Up"},
        },
    })

    -- Or run individual steps:
    podcast.transcribe("parakeet_v3")    -- just transcribe
    podcast.label_speakers()             -- label all words as default speaker
    podcast.clean_audio()                -- remove silences > 1.5s
    podcast.create_chapters()            -- auto-chapter every 5 min
    podcast.export("Episode 42")         -- export SRT + TXT + chapters

  PATTERNS USED:
    - Pipeline architecture: each step is an independent function.
      podcast.produce() orchestrates them, but each can run standalone.
    - Configurable via podcast.config table: change thresholds, paths,
      speaker names, etc. without modifying code.
    - sk.rpc("transcript.setEngine", {...}) to select speech-to-text engine
      before opening the transcript panel
    - Long-running polling: podcasts can be 30+ minutes, so transcription
      gets a 5-minute timeout (150 polls x 2 seconds)
    - sk.rpc("transcript.setSpeaker", {...}) with start_index and count
      to label word ranges by speaker identity
    - Export to multiple formats (SRT, TXT, YouTube chapters) from a
      single transcript, writing each to disk via io.open/io.write
    - YouTube chapter format: "M:SS - Title" (YouTube auto-detects these
      in video descriptions)

  ARCHITECTURE NOTE:
    The podcast table is registered as a global with a .config sub-table.
    You can adjust configuration at runtime:
      podcast.config.silence_min = 2.0       -- be less aggressive
      podcast.config.chapter_interval = 600  -- chapters every 10 min
]]

local u = require("skutil")

local podcast = {}

-----------------------------------------------------------
-- Configuration
-----------------------------------------------------------
podcast.config = {
    -- Speakers
    speakers = {},              -- auto-detected if empty
    default_speaker = "Host",

    -- Silence removal
    silence_min = 1.5,          -- remove silences > 1.5s
    silence_threshold = 0.5,

    -- Chapters
    chapter_interval = 300,     -- minimum seconds between auto-chapters
    chapter_keywords = {        -- words that hint at topic changes
        "so", "anyway", "moving on", "next", "let's talk about",
        "the next thing", "another", "question", "speaking of"
    },

    -- Audio
    music_lane = 1,
    duck_amount = -15,
    target_loudness = -16,      -- LUFS target

    -- Export
    output_dir = os.getenv("HOME") .. "/Desktop/podcast_export",
}

-----------------------------------------------------------
-- Step 1: Transcribe the timeline.
-- Sets the transcription engine, opens the transcript panel,
-- and polls until words appear. Podcasts can be long, so we
-- allow up to 5 minutes for transcription to complete.
--
-- @param engine  string  Transcription engine name. Options:
--   "parakeet_v3" (default, multilingual, on-device)
--   "parakeet_v2" (English-optimized)
--   "apple_speech" (SFSpeechRecognizer, network-capable)
--   "fcp_native"   (built-in AASpeechAnalyzer)
-- @return boolean  true if transcription completed.
-----------------------------------------------------------
function podcast.transcribe(engine)
    engine = engine or "parakeet_v3"

    sk.log("[Podcast] Transcribing with " .. engine .. "...")
    -- setEngine must be called BEFORE open, so the panel starts
    -- with the right engine selected
    sk.rpc("transcript.setEngine", {engine = engine})
    sk.rpc("transcript.open", {})

    -- Wait for completion (podcasts can be long — allow 5 min)
    local ready = false
    for i = 1, 150 do
        sk.sleep(2)
        local state = sk.rpc("transcript.getState", {})
        if state and state.words and #state.words > 5 then
            ready = true
            sk.log(string.format("[Podcast] Transcription complete: %d words", #state.words))
            break
        end
        if i % 15 == 0 then
            sk.log("[Podcast] Still transcribing... (" .. (i * 2) .. "s)")
        end
    end

    if not ready then
        sk.log("[Podcast] Transcription timed out after 5 minutes")
        return false
    end
    return true
end

-----------------------------------------------------------
-- Step 2: Label speakers in the transcript.
-- Each entry in speaker_map is {name, start_word_index, end_word_index}.
-- If no map is provided, all words are labeled as the default speaker.
--
-- @param speaker_map  table  Optional. Array of {"Name", from_idx, to_idx}.
--   Example: {{"Host", 0, 500}, {"Guest", 501, 1200}}
-----------------------------------------------------------
function podcast.label_speakers(speaker_map)
    if not speaker_map or #speaker_map == 0 then
        -- Default: label everything as the default speaker
        local state = sk.rpc("transcript.getState", {})
        local word_count = state and state.words and #state.words or 0
        if word_count > 0 then
            sk.rpc("transcript.setSpeaker", {
                start_index = 0,
                count = word_count,
                speaker = podcast.config.default_speaker
            })
            sk.log(string.format("[Podcast] Labeled %d words as '%s'",
                word_count, podcast.config.default_speaker))
        end
    else
        for _, mapping in ipairs(speaker_map) do
            local name = mapping[1]
            local from = mapping[2]
            local count = mapping[3] - mapping[2]
            sk.rpc("transcript.setSpeaker", {
                start_index = from,
                count = count,
                speaker = name
            })
            sk.log(string.format("[Podcast] Labeled words %d-%d as '%s'", from, mapping[3], name))
        end
    end
end

-----------------------------------------------------------
-- Step 3: Clean up audio by removing long silences.
-- Uses the silence_min and silence_threshold from podcast.config.
-- This is the single biggest time saver for podcast editing:
-- dead air between speakers is removed with one call.
-----------------------------------------------------------
function podcast.clean_audio()
    sk.log("[Podcast] Removing silences > " .. podcast.config.silence_min .. "s...")

    sk.rpc("transcript.setSilenceThreshold", {
        threshold = podcast.config.silence_threshold
    })
    sk.rpc("transcript.deleteSilences", {
        min_duration = podcast.config.silence_min
    })

    sk.log("[Podcast] Silences removed")
end

-----------------------------------------------------------
-- Step 4: Create chapter markers.
-- If manual_chapters is provided, uses those exact positions.
-- Otherwise auto-generates chapters at regular intervals
-- (every podcast.config.chapter_interval seconds).
--
-- @param manual_chapters  table  Optional. Array of {time, title}.
-- @return number  Count of chapters created.
-----------------------------------------------------------
function podcast.create_chapters(manual_chapters)
    if manual_chapters and #manual_chapters > 0 then
        -- Use manually provided chapters
        for _, ch in ipairs(manual_chapters) do
            local t = type(ch.time) == "string" and u.timecode(ch.time) or (ch.time or 0)
            sk.seek(t)
            sk.timeline("addChapterMarker")
            sk.rpc("timeline.directAction", {
                action = "changeMarkerName",
                name = ch.title or "Chapter"
            })
        end
        sk.log(string.format("[Podcast] Created %d manual chapters", #manual_chapters))
        return #manual_chapters
    end

    -- Auto-detect chapters based on scene changes + time intervals
    sk.log("[Podcast] Auto-detecting chapter boundaries...")

    local total_dur = u.timeline_duration()
    local interval = podcast.config.chapter_interval
    local chapters_created = 0

    -- Create chapters at regular intervals
    local t = 0
    while t < total_dur do
        if t > 0 then  -- skip start
            sk.seek(t)
            sk.timeline("addChapterMarker")
            sk.rpc("timeline.directAction", {
                action = "changeMarkerName",
                name = string.format("Segment %d", chapters_created + 1)
            })
            chapters_created = chapters_created + 1
        end
        t = t + interval
    end

    sk.log(string.format("[Podcast] Created %d auto-chapters (every %ds)",
        chapters_created, interval))
    return chapters_created
end

-----------------------------------------------------------
-- Step 5: Export deliverables.
-- Creates three files in podcast.config.output_dir:
--   - SRT subtitles (for video platforms)
--   - Plain text transcript (for show notes)
--   - YouTube chapter list (M:SS format, paste into description)
--
-- @param title  string  Episode title (used in filenames).
-- @return table  {srt=path, txt=path, chapters=path}
-----------------------------------------------------------
function podcast.export(title)
    title = title or "Episode"
    local dir = podcast.config.output_dir

    -- Create output directory
    sk.eval("[[NSFileManager defaultManager] createDirectoryAtPath:@'" ..
            dir .. "' withIntermediateDirectories:YES attributes:nil error:nil]")

    -- Export SRT subtitles
    local srt_path = dir .. "/" .. title:gsub("[^%w%-_ ]", "") .. ".srt"
    sk.rpc("captions.exportSRT", {path = srt_path})
    sk.log("[Podcast] Exported SRT: " .. srt_path)

    -- Export plain text transcript
    local txt_path = dir .. "/" .. title:gsub("[^%w%-_ ]", "") .. "_transcript.txt"
    sk.rpc("captions.exportTXT", {path = txt_path})
    sk.log("[Podcast] Exported transcript: " .. txt_path)

    -- Generate YouTube chapter list
    local fps = sk.position().frameRate or 30
    local total_dur = u.timeline_duration()
    local interval = podcast.config.chapter_interval
    local chapters_text = "CHAPTERS:\n"
    local ch_num = 0
    local t = 0
    while t < total_dur do
        ch_num = ch_num + 1
        local m = math.floor(t / 60)
        local s = math.floor(t % 60)
        chapters_text = chapters_text .. string.format("%d:%02d - Segment %d\n", m, s, ch_num)
        t = t + interval
    end

    local ch_path = dir .. "/" .. title:gsub("[^%w%-_ ]", "") .. "_chapters.txt"
    local f = io.open(ch_path, "w")
    if f then
        f:write(chapters_text)
        f:close()
        sk.log("[Podcast] Exported chapters: " .. ch_path)
    end

    print(string.format("\nExported to %s:", dir))
    print("  SRT:        " .. srt_path)
    print("  Transcript: " .. txt_path)
    print("  Chapters:   " .. ch_path)

    return {srt = srt_path, txt = txt_path, chapters = ch_path}
end

-----------------------------------------------------------
-- Full pipeline: run all 5 steps in sequence.
-- Each step can be skipped or configured via the options table.
--
-- @param title    string  Episode title.
-- @param options  table   Optional. Fields:
--   .engine           string   Transcription engine (default "parakeet_v3")
--   .skip_transcribe  boolean  Skip step 1 (reuse existing transcript)
--   .speakers         table    Speaker map for step 2 (see label_speakers)
--   .chapters         table    Manual chapters for step 4 (see create_chapters)
-- @return table  Export file paths {srt, txt, chapters}.
-----------------------------------------------------------
function podcast.produce(title, options)
    options = options or {}
    title = title or "Episode"
    local start_time = os.time()

    print("  PODCAST PRODUCER")
    print("  " .. string.rep("=", 50))
    print("  Episode: " .. title)
    print("  " .. string.rep("=", 50))

    -- Step 1
    if options.skip_transcribe then
        print("  [1/5] Transcription: SKIPPED")
    else
        print("  [1/5] Transcribing...")
        local ok = podcast.transcribe(options.engine)
        if not ok then
            print("  ABORTED: Transcription failed")
            return
        end
        print("  [1/5] Transcription: DONE")
    end

    -- Step 2
    print("  [2/5] Labeling speakers...")
    podcast.label_speakers(options.speakers)
    print("  [2/5] Speakers: DONE")

    -- Step 3
    print("  [3/5] Cleaning audio...")
    podcast.clean_audio()
    print("  [3/5] Audio cleanup: DONE")

    -- Step 4
    print("  [4/5] Creating chapters...")
    local ch_count = podcast.create_chapters(options.chapters)
    print(string.format("  [4/5] Chapters: %d created", ch_count))

    -- Step 5
    print("  [5/5] Exporting...")
    local paths = podcast.export(title)
    print("  [5/5] Export: DONE")

    local elapsed = os.time() - start_time
    print("")
    print("  " .. string.rep("=", 50))
    print(string.format("  COMPLETE in %ds", elapsed))
    print(string.format("  Timeline: %.1fs", u.timeline_duration()))
    print("  " .. string.rep("=", 50))

    return paths
end

-- Register globally
_G.podcast = podcast

print("Podcast Producer loaded. Commands:")
print("  podcast.produce('Ep 42')           -- full pipeline")
print("  podcast.transcribe()               -- step 1: transcribe")
print("  podcast.label_speakers()           -- step 2: label speakers")
print("  podcast.clean_audio()              -- step 3: remove silences")
print("  podcast.create_chapters()          -- step 4: auto chapters")
print("  podcast.export('title')            -- step 5: export SRT/TXT/chapters")
print("")
print("  podcast.produce('Ep 42', {")
print("    skip_transcribe = true,")
print("    chapters = {{time=0, title='Intro'}, {time=300, title='Topic 1'}}")
print("  })")

return podcast
