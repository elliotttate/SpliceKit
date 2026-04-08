--[[
  Rough Cut from Transcript
  ─────────────────────────
  Transcribes the timeline, removes silences and filler words,
  then labels speakers. Produces a tight rough cut automatically.

  HOW TO USE:
    1. Open a project that contains interview or talking-head footage.
    2. Adjust SILENCE_MIN and FILLER_WORDS below if needed.
    3. Run:  dofile("examples/rough_cut_from_transcript.lua")
    4. Wait for transcription (may take 30-120s depending on length).
    The script removes dead air and reports filler word counts.

  PATTERNS USED:
    - sk.rpc("transcript.open", {})  -- opens the transcript panel and
      starts transcription using the selected engine (Parakeet by default)
    - Polling loop with sk.sleep() to wait for an async operation
    - sk.rpc("transcript.deleteSilences", {...}) -- batch silence removal
    - sk.rpc("transcript.search", {query=...}) -- full-text search over words
    - sk.rpc("transcript.setSpeaker", {...}) -- label word ranges by speaker

  Inspired by CommandPost's text-based editing workflows.
]]

-- Configuration
local SILENCE_MIN     = 0.8   -- remove silences longer than this (seconds)
local FILLER_WORDS    = {"um", "uh", "like", "you know", "basically", "actually", "so,"}
local DEFAULT_SPEAKER = "Host"

-- Step 1: Open transcript and wait for transcription
-- transcript.open triggers the speech-to-text engine; it runs async.
sk.log("[RoughCut] Starting transcription...")
sk.rpc("transcript.open", {})

-- Poll until transcription is done (check every 2 seconds, max 2 minutes).
-- WHY poll: transcript.open returns immediately; the actual transcription
-- runs on a background thread. We check getState until words appear.
local ready = false
for attempt = 1, 60 do
    sk.sleep(2)
    local state = sk.rpc("transcript.getState", {})
    if state and state.words and #state.words > 0 then
        ready = true
        sk.log("[RoughCut] Transcription complete: " .. #state.words .. " words")
        break
    end
end

if not ready then
    sk.log("[RoughCut] Transcription timed out")
    return
end

-- Step 2: Remove silences
-- deleteSilences performs blade + ripple-delete on every silence region
-- longer than min_duration. This is a single RPC call that can remove
-- dozens of gaps at once -- much faster than scripting individual deletes.
sk.log("[RoughCut] Removing silences > " .. SILENCE_MIN .. "s...")
local silence_result = sk.rpc("transcript.deleteSilences", {
    min_duration = SILENCE_MIN
})
sk.log("[RoughCut] Silences removed")

-- Step 3: Search for and count filler words
-- We re-fetch the transcript state because word indices shifted after
-- the silence deletions above.
local transcript = sk.rpc("transcript.getState", {})
local total_fillers = 0

for _, filler in ipairs(FILLER_WORDS) do
    local results = sk.rpc("transcript.search", {query = filler})
    if results and results.count and results.count > 0 then
        sk.log("[RoughCut] Found " .. results.count .. " instances of '" .. filler .. "'")
        total_fillers = total_fillers + results.count
    end
end

-- Step 4: Label the default speaker
-- setSpeaker assigns a speaker name to a range of word indices. Here we
-- label everything as one speaker; for multi-speaker content, call it
-- multiple times with different index ranges.
if transcript.words and #transcript.words > 0 then
    sk.rpc("transcript.setSpeaker", {
        start_index = 0,
        count = #transcript.words,
        speaker = DEFAULT_SPEAKER
    })
    sk.log("[RoughCut] Labeled all words as '" .. DEFAULT_SPEAKER .. "'")
end

-- Step 5: Report
local final = sk.rpc("transcript.getState", {})
local word_count = final.words and #final.words or 0
sk.log(string.format(
    "[RoughCut] Done! %d words, %d fillers found, silences removed",
    word_count, total_fillers
))
