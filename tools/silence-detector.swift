#!/usr/bin/env swift
//
//  silence-detector.swift
//  Analyzes audio in media files to find silent time ranges.
//  Uses AVAssetReader + vDSP (Accelerate) — all Apple-native, no ffmpeg.
//
//  Usage: silence-detector <file> [--threshold auto] [--min-duration 0.5] [--padding 0.08]
//  Output: JSON with silent time ranges
//

import AVFoundation
import Accelerate
import Foundation

// MARK: - Types

struct SilentRange: Codable {
    let start: Double
    let end: Double
    let duration: Double
}

struct AnalysisResult: Codable {
    let filePath: String
    let totalDuration: Double
    let silentRanges: [SilentRange]
    let analysisRange: AnalysisRange?
    let settings: Settings

    struct AnalysisRange: Codable {
        let start: Double
        let end: Double
    }
    struct Settings: Codable {
        let thresholdDB: Double
        let computedThresholdDB: Double?
        let noiseFloorDB: Double?
        let speechLevelDB: Double?
        let minSilenceDuration: Double
        let padding: Double
        let chunkSizeMs: Double
    }
}

// MARK: - High-pass filter (removes room tone below cutoff)

/// Simple 2nd-order Butterworth high-pass filter coefficients
func highPassCoefficients(cutoff: Double, sampleRate: Double) -> [Double] {
    let w0 = 2.0 * Double.pi * cutoff / sampleRate
    let alpha = sin(w0) / (2.0 * 0.7071) // Q = 0.7071 for Butterworth
    let cosW0 = cos(w0)
    let a0 = 1.0 + alpha
    // biquad coefficients: b0, b1, b2, a1, a2 (normalized by a0)
    let b0 = ((1.0 + cosW0) / 2.0) / a0
    let b1 = (-(1.0 + cosW0)) / a0
    let b2 = ((1.0 + cosW0) / 2.0) / a0
    let a1 = (-2.0 * cosW0) / a0
    let a2 = (1.0 - alpha) / a0
    return [b0, b1, b2, a1, a2]
}

func applyHighPass(samples: UnsafeMutablePointer<Float>, count: Int, cutoff: Double, sampleRate: Double) {
    let c = highPassCoefficients(cutoff: cutoff, sampleRate: sampleRate)
    // vDSP_deq22 coefficients: [b0, b1, b2, a1, a2]
    var coeffs: [Double] = c
    // Manual biquad: y[n] = b0*x[n] + b1*x[n-1] + b2*x[n-2] - a1*y[n-1] - a2*y[n-2]
    var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0
    let b0 = Float(c[0]), b1 = Float(c[1]), b2 = Float(c[2])
    let a1 = Float(c[3]), a2 = Float(c[4])
    for i in 0..<count {
        let x0 = samples[i]
        let y0 = b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        samples[i] = y0
        x2 = x1; x1 = x0
        y2 = y1; y1 = y0
    }
}

// MARK: - Read audio RMS values

func readRMSValues(
    filePath: String,
    startTime: Double?,
    endTime: Double?,
    chunkSize: Int = 4096
) -> (rmsValues: [(time: Double, rms: Float)], totalDuration: Double)? {
    let url = URL(fileURLWithPath: filePath)
    let asset = AVURLAsset(url: url)

    let semaphore = DispatchSemaphore(value: 0)
    var audioTrack: AVAssetTrack?
    asset.loadTracks(withMediaType: .audio) { tracks, error in
        audioTrack = tracks?.first
        semaphore.signal()
    }
    semaphore.wait()

    guard let track = audioTrack else {
        fputs("Error: No audio track found in \(filePath)\n", stderr)
        return nil
    }

    let totalDuration = CMTimeGetSeconds(asset.duration)

    let reader: AVAssetReader
    do {
        reader = try AVAssetReader(asset: asset)
    } catch {
        fputs("Error creating AVAssetReader: \(error)\n", stderr)
        return nil
    }

    if let start = startTime {
        let end = endTime ?? totalDuration
        reader.timeRange = CMTimeRange(
            start: CMTimeMakeWithSeconds(start, preferredTimescale: 44100),
            end: CMTimeMakeWithSeconds(end, preferredTimescale: 44100)
        )
    }

    let outputSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsNonInterleaved: false,
        AVSampleRateKey: 44100,
        AVNumberOfChannelsKey: 1
    ]

    let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
    output.alwaysCopiesSampleData = false
    reader.add(output)

    guard reader.startReading() else {
        fputs("Error starting reader: \(reader.error?.localizedDescription ?? "unknown")\n", stderr)
        return nil
    }

    let sampleRate: Double = 44100.0
    var rmsValues: [(time: Double, rms: Float)] = []
    var totalSamplesProcessed = 0
    let analysisStartTime = startTime ?? 0.0

    // Accumulate samples across buffers to handle small buffer sizes
    var accumulator = [Float]()

    while let sampleBuffer = output.copyNextSampleBuffer() {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
        let length = CMBlockBufferGetDataLength(blockBuffer)
        let floatCount = length / MemoryLayout<Float>.size
        guard floatCount > 0 else { continue }

        var dataPointer: UnsafeMutablePointer<Int8>?
        var lengthAtOffset: Int = 0
        let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset, totalLengthOut: nil, dataPointerOut: &dataPointer)
        guard status == kCMBlockBufferNoErr, let rawPtr = dataPointer else { continue }

        rawPtr.withMemoryRebound(to: Float.self, capacity: floatCount) { floatPtr in
            accumulator.append(contentsOf: UnsafeBufferPointer(start: floatPtr, count: floatCount))
        }

        // Process complete chunks from accumulator
        while accumulator.count >= chunkSize {
            accumulator.withUnsafeBufferPointer { buf in
                var rms: Float = 0
                vDSP_rmsqv(buf.baseAddress!, 1, &rms, vDSP_Length(chunkSize))
                let timeSeconds = analysisStartTime + Double(totalSamplesProcessed) / sampleRate
                rmsValues.append((time: timeSeconds, rms: rms))
            }
            accumulator.removeFirst(chunkSize)
            totalSamplesProcessed += chunkSize
        }
    }

    return (rmsValues, totalDuration)
}

// MARK: - Adaptive threshold using energy variance

/// Classify each chunk as speech or silence using a sliding window variance approach.
/// Speech causes RMS to fluctuate; silence/room tone has constant energy.
func classifySpeechSilence(
    rmsValues: [(time: Double, rms: Float)],
    windowChunks: Int = 8  // ~0.75s window at 4096/44100
) -> (isSpeech: [Bool], noiseFloorDB: Double, speechDB: Double) {
    let count = rmsValues.count
    guard count > windowChunks else { return (Array(repeating: false, count: count), -96, -96) }

    let dbValues = rmsValues.map { $0.rms > 0 ? 20.0 * log10(Double($0.rms)) : -96.0 }

    // Compute sliding window variance of dB values
    var variances = [Double](repeating: 0, count: count)
    let half = windowChunks / 2
    for i in 0..<count {
        let lo = max(0, i - half)
        let hi = min(count - 1, i + half)
        let n = hi - lo + 1
        var sum = 0.0, sumSq = 0.0
        for j in lo...hi {
            sum += dbValues[j]
            sumSq += dbValues[j] * dbValues[j]
        }
        let mean = sum / Double(n)
        variances[i] = sumSq / Double(n) - mean * mean
    }

    // Find threshold: sort variances, pick a point that separates low-variance (silence) from high-variance (speech)
    let sortedVar = variances.sorted()
    let medianVar = sortedVar[count / 2]

    // Chunks with variance > median * 0.3 are speech (they have more fluctuation)
    // Use a minimum variance floor to avoid false positives in very quiet content
    let varThreshold = max(medianVar * 0.3, 0.5)

    var isSpeech = variances.map { $0 > varThreshold }

    // Smooth: fill small gaps in speech (< 3 chunks ≈ 0.28s)
    for i in 0..<count {
        if !isSpeech[i] {
            let lookback = max(0, i - 3)
            let lookahead = min(count - 1, i + 3)
            let backSpeech = (lookback..<i).contains(where: { isSpeech[$0] })
            let aheadSpeech = i + 1 <= lookahead && (i+1...lookahead).contains(where: { isSpeech[$0] })
            if backSpeech && aheadSpeech { isSpeech[i] = true }
        }
    }

    // Also mark as speech if the absolute level is significantly above the noise floor
    let sortedDB = dbValues.sorted()
    let noiseFloor = sortedDB[max(0, count / 10)]
    let speechLevel = sortedDB[min(count - 1, count * 8 / 10)]

    // If a chunk is > noise floor + 70% of dynamic range, it's definitely speech
    let highLevelThreshold = noiseFloor + (speechLevel - noiseFloor) * 0.7
    for i in 0..<count {
        if dbValues[i] > highLevelThreshold { isSpeech[i] = true }
    }

    return (isSpeech, noiseFloor, speechLevel)
}

// MARK: - Find silent ranges from RMS values

func findSilentRanges(
    rmsValues: [(time: Double, rms: Float)],
    thresholdLinear: Float,
    minSilenceDuration: Double,
    padding: Double,
    totalDuration: Double,
    startTime: Double?
) -> [SilentRange] {
    var silentRanges: [SilentRange] = []
    var currentSilenceStart: Double? = nil

    for (time, rms) in rmsValues {
        if rms <= thresholdLinear {
            if currentSilenceStart == nil {
                currentSilenceStart = time
            }
        } else {
            if let silStart = currentSilenceStart {
                let silDuration = time - silStart
                if silDuration >= minSilenceDuration {
                    let paddedStart = silStart + padding
                    let paddedEnd = time - padding
                    if paddedEnd > paddedStart {
                        silentRanges.append(SilentRange(
                            start: paddedStart, end: paddedEnd,
                            duration: paddedEnd - paddedStart
                        ))
                    }
                }
                currentSilenceStart = nil
            }
        }
    }

    // Handle trailing silence
    if let silStart = currentSilenceStart {
        let endSeconds = rmsValues.last?.time ?? (startTime ?? 0.0)
        let silDuration = endSeconds - silStart
        if silDuration >= minSilenceDuration {
            let paddedStart = silStart + padding
            let paddedEnd = endSeconds - padding
            if paddedEnd > paddedStart {
                silentRanges.append(SilentRange(
                    start: paddedStart, end: paddedEnd,
                    duration: paddedEnd - paddedStart
                ))
            }
        }
    }

    return silentRanges
}

// MARK: - Main analysis

func analyzeAudio(
    filePath: String,
    thresholdDB: Double?,  // nil = auto
    minSilenceDuration: Double,
    padding: Double,
    startTime: Double?,
    endTime: Double?
) -> AnalysisResult? {
    guard let (rmsValues, totalDuration) = readRMSValues(
        filePath: filePath, startTime: startTime, endTime: endTime
    ) else { return nil }

    guard !rmsValues.isEmpty else {
        fputs("Error: No audio data read\n", stderr)
        return nil
    }

    let sampleRate: Double = 44100.0
    let chunkSize = 4096
    let chunkMs = Double(chunkSize) / sampleRate * 1000.0

    var noiseFloorDB: Double? = nil
    var speechDB: Double? = nil
    var computedDB: Double? = nil
    let effectiveDB: Double
    let silentRanges: [SilentRange]

    if let manualDB = thresholdDB {
        // Fixed threshold mode
        let thresholdLinear = Float(pow(10.0, manualDB / 20.0))
        effectiveDB = manualDB
        silentRanges = findSilentRanges(
            rmsValues: rmsValues,
            thresholdLinear: thresholdLinear,
            minSilenceDuration: minSilenceDuration,
            padding: padding,
            totalDuration: totalDuration,
            startTime: startTime
        )
    } else {
        // Adaptive mode: use energy variance to classify speech vs silence
        let (isSpeech, noise, speech) = classifySpeechSilence(rmsValues: rmsValues)
        noiseFloorDB = noise
        speechDB = speech
        effectiveDB = noise + (speech - noise) * 0.35
        computedDB = effectiveDB
        fputs("Adaptive: noise=\(String(format: "%.1f", noise)) dB, speech=\(String(format: "%.1f", speech)) dB\n", stderr)

        // Convert isSpeech classification to silent ranges
        var ranges: [SilentRange] = []
        var silenceStart: Double? = nil
        for i in 0..<rmsValues.count {
            let time = rmsValues[i].time
            if !isSpeech[i] {
                if silenceStart == nil { silenceStart = time }
            } else {
                if let start = silenceStart {
                    let dur = time - start
                    if dur >= minSilenceDuration {
                        let ps = start + padding
                        let pe = time - padding
                        if pe > ps { ranges.append(SilentRange(start: ps, end: pe, duration: pe - ps)) }
                    }
                    silenceStart = nil
                }
            }
        }
        // Trailing silence
        if let start = silenceStart, let lastTime = rmsValues.last?.time {
            let dur = lastTime - start
            if dur >= minSilenceDuration {
                let ps = start + padding
                let pe = lastTime - padding
                if pe > ps { ranges.append(SilentRange(start: ps, end: pe, duration: pe - ps)) }
            }
        }
        silentRanges = ranges
    }

    var analysisRange: AnalysisResult.AnalysisRange? = nil
    if let start = startTime {
        analysisRange = .init(start: start, end: endTime ?? totalDuration)
    }

    return AnalysisResult(
        filePath: filePath,
        totalDuration: totalDuration,
        silentRanges: silentRanges,
        analysisRange: analysisRange,
        settings: .init(
            thresholdDB: effectiveDB,
            computedThresholdDB: computedDB,
            noiseFloorDB: noiseFloorDB,
            speechLevelDB: speechDB,
            minSilenceDuration: minSilenceDuration,
            padding: padding,
            chunkSizeMs: chunkMs
        )
    )
}

// MARK: - Argument Parsing

var filePath: String?
var thresholdDB: Double? = nil  // nil = auto
var minSilenceDuration = 0.5
var padding = 0.08
var startTime: Double?
var endTime: Double?

var i = 1
let cliArgs = CommandLine.arguments
while i < cliArgs.count {
    let arg = cliArgs[i]
    switch arg {
    case "--threshold":
        i += 1
        if i < cliArgs.count {
            if cliArgs[i] == "auto" {
                thresholdDB = nil
            } else {
                thresholdDB = Double(cliArgs[i])
            }
        }
    case "--min-duration":
        i += 1
        if i < cliArgs.count { minSilenceDuration = Double(cliArgs[i]) ?? 0.5 }
    case "--padding":
        i += 1
        if i < cliArgs.count { padding = Double(cliArgs[i]) ?? 0.08 }
    case "--start":
        i += 1
        if i < cliArgs.count { startTime = Double(cliArgs[i]) }
    case "--end":
        i += 1
        if i < cliArgs.count { endTime = Double(cliArgs[i]) }
    case "--help", "-h":
        print("""
        Usage: silence-detector <file> [options]

        Options:
          --threshold <dB|auto>   RMS threshold in dB, or "auto" for adaptive (default: auto)
          --min-duration <sec>    Minimum silence duration in seconds (default: 0.5)
          --padding <sec>         Padding to keep before/after cuts (default: 0.08)
          --start <sec>           Start analysis at this time (default: file start)
          --end <sec>             End analysis at this time (default: file end)

        Output: JSON to stdout with detected silent time ranges.
        """)
        exit(0)
    default:
        if !arg.hasPrefix("-") {
            filePath = arg
        } else {
            fputs("Unknown option: \(arg)\n", stderr)
            exit(1)
        }
    }
    i += 1
}

guard let path = filePath else {
    fputs("Usage: silence-detector <file> [--threshold auto] [--min-duration 0.5] [--padding 0.08]\n", stderr)
    exit(1)
}

guard FileManager.default.fileExists(atPath: path) else {
    fputs("Error: File not found: \(path)\n", stderr)
    exit(1)
}

guard let result = analyzeAudio(
    filePath: path,
    thresholdDB: thresholdDB,
    minSilenceDuration: minSilenceDuration,
    padding: padding,
    startTime: startTime,
    endTime: endTime
) else {
    exit(1)
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
do {
    let jsonData = try encoder.encode(result)
    print(String(data: jsonData, encoding: .utf8)!)
} catch {
    fputs("Error encoding JSON: \(error)\n", stderr)
    exit(1)
}
