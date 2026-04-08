-- Transcribe timeline and remove silences longer than 1 second
sk.toast("Transcribing timeline...")
sk.rpc("transcript.open", {})

local ready = false
for i = 1, 60 do
    sk.sleep(2)
    local state = sk.rpc("transcript.getState", {})
    if state and state.words and #state.words > 0 then
        ready = true
        break
    end
end

if not ready then
    sk.alert("Remove Silences", "Transcription timed out. Try again with a shorter timeline.")
    return
end

local ts = sk.rpc("transcript.getState", {})
local word_count = ts.words and #ts.words or 0

sk.rpc("transcript.deleteSilences", {min_duration = 1.0})

sk.alert("Remove Silences",
    string.format("Done!\n\nTranscribed %d words.\nRemoved silences > 1 second.", word_count))
