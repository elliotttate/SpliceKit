import Foundation
import FluidAudio

// Usage:
//   parakeet-transcriber <audio-file> [--progress] [--speakers] [--model v2|v3|110m]
//   parakeet-transcriber --batch <json-file> [--progress] [--speakers] [--model v2|v3|110m]
//
// Single mode: outputs JSON array of word objects to stdout
// Batch mode:  reads JSON array of {"file":"path"} from <json-file>,
//              outputs JSON array of {"file":"path","words":[...]} to stdout
//              Model is loaded once and reused for all files.
//              Files are transcribed concurrently with diarization for max throughput.
//
// Progress: lines like "PROGRESS:<fraction>:<message>" to stderr when --progress is set
// Uses NVIDIA Parakeet TDT 0.6B via FluidAudio (fast, on-device)
//   v3 = multilingual (25 languages), v2 = English-optimized
// Speaker diarization via FluidAudio OfflineDiarizerManager (pyannote-based)

import os.log
let progressLock = NSLock()

func reportProgress(_ fraction: Double, _ message: String) {
    progressLock.lock()
    let line = "PROGRESS:\(fraction):\(message)\n"
    FileHandle.standardError.write(line.data(using: .utf8)!)
    progressLock.unlock()
}

func printError(_ message: String) {
    progressLock.lock()
    FileHandle.standardError.write("ERROR:\(message)\n".data(using: .utf8)!)
    progressLock.unlock()
}

/// Extract word list from an ASR result, optionally assigning speakers from diarization segments
func extractWords(from result: ASRResult, speakerSegments: [TimedSpeakerSegment] = []) -> [[String: Any]] {
    var words: [[String: Any]] = []

    if let tokenTimings = result.tokenTimings {
        let textWords = result.text.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        var tokenIndex = 0

        for textWord in textWords {
            var accumulated = ""
            var startTime: Float?
            var endTime: Float = 0
            var minConfidence: Float = 1.0

            while tokenIndex < tokenTimings.count {
                let timing = tokenTimings[tokenIndex]
                let token = timing.token.trimmingCharacters(in: .whitespacesAndNewlines)
                tokenIndex += 1
                if token.isEmpty { continue }

                if startTime == nil { startTime = Float(timing.startTime) }
                endTime = Float(timing.endTime)
                minConfidence = min(minConfidence, timing.confidence)
                accumulated += token

                if accumulated == textWord || accumulated.count >= textWord.count { break }
            }

            let trimmed = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let start = startTime else { continue }

            var speaker = "Unknown"
            if !speakerSegments.isEmpty {
                let wordMid = (start + endTime) / 2.0
                for seg in speakerSegments {
                    if wordMid >= seg.startTimeSeconds && wordMid <= seg.endTimeSeconds {
                        speaker = seg.speakerId
                        break
                    }
                }
            }

            var wordDict: [String: Any] = [
                "word": trimmed,
                "startTime": start,
                "endTime": endTime,
                "confidence": minConfidence,
            ]
            if speaker != "Unknown" { wordDict["speaker"] = speaker }
            words.append(wordDict)
        }
    } else {
        words.append([
            "word": result.text,
            "startTime": Float(0),
            "endTime": Float(result.duration),
            "confidence": result.confidence,
        ])
    }

    return words
}

let args = CommandLine.arguments

guard args.count >= 2 else {
    printError("Usage: parakeet-transcriber <audio-file> [--progress] [--speakers] [--model v2|v3|110m]")
    printError("       parakeet-transcriber --batch <manifest.json> [--progress] [--speakers] [--model v2|v3|110m]")
    exit(1)
}

let showProgress = args.contains("--progress")
let detectSpeakers = args.contains("--speakers")
let batchMode = args.contains("--batch")

// Parse --model flag (default: v3)
var modelVersion: AsrModelVersion = .v3
if let modelIdx = args.firstIndex(of: "--model"), modelIdx + 1 < args.count {
    switch args[modelIdx + 1].lowercased() {
    case "v2": modelVersion = .v2
    case "v3": modelVersion = .v3
    case "110m", "tdtctc110m": modelVersion = .tdtCtc110m
    default: printError("Unknown model version '\(args[modelIdx + 1])' — using v3")
    }
}

// Determine input files
struct BatchEntry {
    let file: String
}

var batchEntries: [BatchEntry] = []

if batchMode {
    guard let batchIdx = args.firstIndex(of: "--batch"), batchIdx + 1 < args.count else {
        printError("--batch requires a manifest JSON file path")
        exit(1)
    }
    let manifestPath = args[batchIdx + 1]
    guard let data = FileManager.default.contents(atPath: manifestPath),
          let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
        printError("Failed to read batch manifest: \(manifestPath)")
        exit(1)
    }
    for entry in arr {
        if let file = entry["file"] as? String {
            batchEntries.append(BatchEntry(file: file))
        }
    }
    if batchEntries.isEmpty {
        printError("No files in batch manifest")
        exit(1)
    }
} else {
    let audioPath = args[1]
    guard FileManager.default.fileExists(atPath: audioPath) else {
        printError("File not found: \(audioPath)")
        exit(1)
    }
    batchEntries.append(BatchEntry(file: audioPath))
}

let semaphore = DispatchSemaphore(value: 0)
var exitCode: Int32 = 0

Task {
    do {
        let versionName: String
        switch modelVersion {
        case .v2: versionName = "v2 (English)"
        case .v3: versionName = "v3 (Multilingual)"
        case .tdtCtc110m: versionName = "110M (Compact)"
        }
        // Check if models need downloading
        let modelDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("FluidAudio/Models")
        let versionFolder: String
        switch modelVersion {
        case .v2: versionFolder = "parakeet-tdt-0.6b-v2"
        case .v3: versionFolder = "parakeet-tdt-0.6b-v3"
        case .tdtCtc110m: versionFolder = "parakeet-tdt-ctc-110m"
        }
        let modelPath = modelDir.appendingPathComponent(versionFolder)
        let needsDownload = !FileManager.default.fileExists(atPath: modelPath.path) ||
            (try? FileManager.default.contentsOfDirectory(atPath: modelPath.path))?.count ?? 0 < 3

        if needsDownload {
            if showProgress { reportProgress(0.03, "Downloading Parakeet \(versionName) model (~475 MB)... This only happens once.") }
            printError("INFO: Model not found at \(modelPath.path) — downloading from HuggingFace...")
        } else {
            if showProgress { reportProgress(0.05, "Loading Parakeet \(versionName) model (cached)...") }
        }

        let models: AsrModels
        do {
            models = try await AsrModels.downloadAndLoad(version: modelVersion)
        } catch {
            let errMsg = error.localizedDescription
            if errMsg.contains("rate") || errMsg.contains("429") || errMsg.contains("503") {
                printError("Model download rate-limited by HuggingFace. Wait a few minutes and try again.")
            } else if errMsg.contains("Could not connect") || errMsg.contains("network") || errMsg.contains("NSURLError") {
                printError("Network error downloading model. Check internet connection. Error: \(errMsg)")
            } else if errMsg.contains("No space") || errMsg.contains("disk") {
                printError("Not enough disk space to download model (~475 MB required). Free up space and try again.")
            } else {
                printError("Failed to download/load model: \(errMsg)")
            }
            printError("TIP: You can manually delete the model cache at ~/Library/Application Support/FluidAudio/Models/ and retry.")
            throw error
        }

        if showProgress { reportProgress(0.12, "Compiling neural network for your device...") }

        let manager = AsrManager(config: .default)
        do {
            try await manager.initialize(models: models)
        } catch {
            printError("Failed to initialize Parakeet engine: \(error.localizedDescription)")
            printError("TIP: This may happen on Intel Macs (Neural Engine required) or with insufficient RAM.")
            throw error
        }

        if showProgress { reportProgress(0.15, "Parakeet ready") }

        // Prepare diarizer once if needed (reuse across all files)
        var sharedDiarizer: OfflineDiarizerManager? = nil
        if detectSpeakers {
            if showProgress { reportProgress(0.17, "Downloading speaker detection models (first time only)...") }
            var config = OfflineDiarizerConfig()
            config.clustering.threshold = 0.45
            config.clustering.minSpeakers = 2
            config.segmentation.stepRatio = 0.1
            sharedDiarizer = OfflineDiarizerManager(config: config)
            do {
                try await sharedDiarizer!.prepareModels()
            } catch {
                printError("Speaker detection model failed to load: \(error.localizedDescription). Continuing without speaker detection.")
                sharedDiarizer = nil
            }
            if showProgress && sharedDiarizer != nil { reportProgress(0.19, "Speaker detection ready") }
        }

        if showProgress { reportProgress(0.20, "Transcribing \(batchEntries.count) file(s)...") }

        let totalFiles = Double(batchEntries.count)

        // Phase 1: Transcribe all files (ASR actor serializes these, runs on ANE)
        var asrResults: [(index: Int, file: String, result: ASRResult)] = []
        for (index, entry) in batchEntries.enumerated() {
            let fileURL = URL(fileURLWithPath: entry.file)
            guard FileManager.default.fileExists(atPath: entry.file) else {
                printError("File not found: \(entry.file)")
                continue
            }
            if showProgress {
                let pct = 0.20 + (0.50 * Double(index) / totalFiles)
                reportProgress(pct, "Transcribing \(index+1)/\(Int(totalFiles)): \(fileURL.lastPathComponent)...")
            }
            let result = try await manager.transcribe(fileURL, source: .system)
            asrResults.append((index: index, file: entry.file, result: result))
        }

        if showProgress { reportProgress(0.70, "Transcription complete — \(asrResults.count) file(s)") }

        // Phase 2: Diarize all files concurrently (CPU-bound, not actor-isolated)
        var diarizationMap: [String: [TimedSpeakerSegment]] = [:]
        if let diarizer = sharedDiarizer {
            if showProgress { reportProgress(0.72, "Detecting speakers across \(asrResults.count) file(s)...") }
            await withTaskGroup(of: (String, [TimedSpeakerSegment]).self) { group in
                for entry in asrResults {
                    let filePath = entry.file
                    group.addTask {
                        let fileURL = URL(fileURLWithPath: filePath)
                        do {
                            let diarResult = try await diarizer.process(fileURL)
                            return (filePath, diarResult.segments)
                        } catch {
                            printError("Diarization failed for \(fileURL.lastPathComponent): \(error.localizedDescription)")
                            return (filePath, [])
                        }
                    }
                }
                for await (file, segments) in group {
                    diarizationMap[file] = segments
                }
            }
            let totalSpeakers = Set(diarizationMap.values.flatMap { $0 }.map { $0.speakerId }).count
            if showProgress { reportProgress(0.90, "Found \(totalSpeakers) speaker(s) across all files") }
        }

        // Phase 3: Build results
        if showProgress { reportProgress(0.92, "Building word lists...") }

        var allResults: [[String: Any]] = []
        // Track missing files for batch mode
        let processedFiles = Set(asrResults.map { $0.file })
        for entry in batchEntries {
            if !processedFiles.contains(entry.file) {
                if batchMode {
                    allResults.append(["file": entry.file, "words": [] as [Any], "error": "File not found"])
                }
            }
        }

        for entry in asrResults {
            let speakerSegments = diarizationMap[entry.file] ?? []
            let words = extractWords(from: entry.result, speakerSegments: speakerSegments)

            if batchMode {
                allResults.append(["file": entry.file, "words": words])
            } else {
                allResults = words
            }
        }

        if showProgress {
            let totalWords = allResults.reduce(0) { sum, r in
                if let words = r["words"] as? [[String: Any]] {
                    return sum + words.count
                } else if r["word"] != nil {
                    return sum + 1
                }
                return sum
            }
            reportProgress(1.0, "Done — \(totalWords) words from \(batchEntries.count) file(s)")
        }

        let jsonData = try JSONSerialization.data(withJSONObject: allResults, options: [.sortedKeys])
        if let jsonString = String(data: jsonData, encoding: .utf8) {
            print(jsonString)
        }

    } catch {
        let errMsg = error.localizedDescription
        printError("Transcription failed: \(errMsg)")
        // Provide actionable guidance based on error type
        if errMsg.contains("memory") || errMsg.contains("Memory") {
            printError("TIP: Close other apps to free memory — Parakeet needs ~1 GB RAM.")
        }
        if errMsg.contains("CoreML") || errMsg.contains("mlmodel") {
            printError("TIP: Try deleting ~/Library/Application Support/FluidAudio/Models/ and re-running.")
        }
        if errMsg.contains("compute") || errMsg.contains("ANE") || errMsg.contains("Neural Engine") {
            printError("TIP: Parakeet requires Apple Silicon (M1 or later). Intel Macs are not supported.")
        }
        exitCode = 1
    }
    semaphore.signal()
}

semaphore.wait()
exit(exitCode)
