#!/usr/bin/env swift
// Beat detector - standalone tool for audio beat/tempo detection
// Reads any audio file and outputs JSON with beats, bars, sections, BPM
// Usage: beat-detector <file_path> [sensitivity] [min_bpm] [max_bpm]

import Foundation
import AVFoundation
import Accelerate

guard CommandLine.arguments.count >= 2 else {
    let err: [String: Any] = ["error": "Usage: beat-detector <file_path> [sensitivity] [min_bpm] [max_bpm]"]
    print(String(data: try! JSONSerialization.data(withJSONObject: err), encoding: .utf8)!)
    exit(1)
}

let filePath = CommandLine.arguments[1]
let sensitivity = CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2]) ?? 0.5 : 0.5
let minBPM = CommandLine.arguments.count > 3 ? Double(CommandLine.arguments[3]) ?? 60.0 : 60.0
let maxBPM = CommandLine.arguments.count > 4 ? Double(CommandLine.arguments[4]) ?? 200.0 : 200.0

func outputJSON(_ dict: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: dict),
       let str = String(data: data, encoding: .utf8) {
        print(str)
    }
}

let fileURL = URL(fileURLWithPath: filePath)
guard FileManager.default.fileExists(atPath: filePath) else {
    outputJSON(["error": "File not found: \(filePath)"])
    exit(1)
}

let asset = AVURLAsset(url: fileURL)
let totalDuration = CMTimeGetSeconds(asset.duration)
guard totalDuration > 0 else {
    outputJSON(["error": "Could not determine audio duration"])
    exit(1)
}

guard let reader = try? AVAssetReader(asset: asset) else {
    outputJSON(["error": "Cannot create asset reader"])
    exit(1)
}

let audioTracks = asset.tracks(withMediaType: .audio)
guard !audioTracks.isEmpty else {
    outputJSON(["error": "No audio tracks in file"])
    exit(1)
}

let outputSettings: [String: Any] = [
    AVFormatIDKey: kAudioFormatLinearPCM,
    AVLinearPCMBitDepthKey: 32,
    AVLinearPCMIsFloatKey: true,
    AVLinearPCMIsBigEndianKey: false,
    AVLinearPCMIsNonInterleaved: false,
    AVSampleRateKey: 44100,
    AVNumberOfChannelsKey: 1
]

let output = AVAssetReaderTrackOutput(track: audioTracks[0], outputSettings: outputSettings)
reader.add(output)
reader.startReading()

var pcmData = Data()
while reader.status == .reading {
    guard let sampleBuffer = output.copyNextSampleBuffer() else { break }
    guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
    var length = 0
    var dataPointer: UnsafeMutablePointer<Int8>?
    CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)
    if let ptr = dataPointer, length > 0 {
        pcmData.append(UnsafeBufferPointer(start: UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt8.self), count: length))
    }
}

guard !pcmData.isEmpty else {
    outputJSON(["error": "Could not read audio samples"])
    exit(1)
}

let sampleCount = pcmData.count / MemoryLayout<Float>.size
let sampleRate: Double = 44100.0

let samples = pcmData.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> [Float] in
    let floatPtr = ptr.bindMemory(to: Float.self)
    return Array(floatPtr)
}

// Onset detection via energy-based peak picking
let hopSize = 512
let windowSize = 1024
let hopDuration = Double(hopSize) / sampleRate

let numFrames = (sampleCount > windowSize) ? (sampleCount - windowSize) / hopSize : 0
guard numFrames >= 10 else {
    outputJSON(["error": "Audio too short for beat detection"])
    exit(1)
}

// Compute RMS energy per window
var energy = [Float](repeating: 0, count: numFrames)
for i in 0..<numFrames {
    let offset = i * hopSize
    var sum: Float = 0
    for j in 0..<windowSize where (offset + j) < sampleCount {
        let s = samples[offset + j]
        sum += s * s
    }
    energy[i] = sqrtf(sum / Float(windowSize))
}

// Local average energy
let avgWindow = max(4, Int(0.5 / hopDuration))
var localAvg = [Float](repeating: 0, count: numFrames)
for i in 0..<numFrames {
    let start = max(0, i - avgWindow)
    let end = min(numFrames, i + avgWindow)
    var sum: Float = 0
    for j in start..<end { sum += energy[j] }
    localAvg[i] = sum / Float(end - start)
}

// Detect onsets
let threshold = 1.3 + (1.0 - sensitivity) * 1.0
let minOnsetInterval = 60.0 / maxBPM
var onsets = [Double]()
var lastOnsetTime = -999.0

for i in 1..<(numFrames - 1) {
    let t = Double(i * hopSize) / sampleRate
    if energy[i] > energy[i-1] && energy[i] > energy[i+1] &&
       energy[i] > localAvg[i] * Float(threshold) &&
       (t - lastOnsetTime) >= minOnsetInterval {
        onsets.append(t)
        lastOnsetTime = t
    }
}

guard onsets.count >= 4 else {
    outputJSON(["error": "Could not detect enough beats in audio"])
    exit(1)
}

// Estimate tempo
var intervals = [Double]()
for i in 1..<onsets.count {
    let interval = onsets[i] - onsets[i-1]
    if interval > 0.1 && interval < 2.0 {
        intervals.append(interval)
    }
}

var bestInterval = 0.5
if !intervals.isEmpty {
    let sorted = intervals.sorted()
    let median = sorted[sorted.count / 2]
    let nearMedian = sorted.filter { abs($0 - median) / median < 0.2 }
    if !nearMedian.isEmpty {
        bestInterval = nearMedian.reduce(0, +) / Double(nearMedian.count)
    }
}

var bpm = 60.0 / bestInterval
while bpm < minBPM && bpm > 0 { bpm *= 2.0 }
while bpm > maxBPM { bpm /= 2.0 }
let beatInterval = 60.0 / bpm

// Find best grid offset
var bestOffset = 0.0
var bestScore = -1.0
for s in 0..<20 {
    let testOffset = beatInterval * Double(s) / 20.0
    var score = 0.0
    for onset in onsets {
        var dist = (onset - testOffset).truncatingRemainder(dividingBy: beatInterval)
        if dist > beatInterval / 2 { dist = beatInterval - dist }
        score += 1.0 / (1.0 + dist * 20.0)
    }
    if score > bestScore {
        bestScore = score
        bestOffset = testOffset
    }
}

// Generate beat grid
var beats = [Double]()
var t = bestOffset
while t < totalDuration {
    beats.append(t)
    t += beatInterval
}

var bars = [Double]()
for i in stride(from: 0, to: beats.count, by: 4) {
    bars.append(beats[i])
}

var sections = [Double]()
for i in stride(from: 0, to: beats.count, by: 16) {
    sections.append(beats[i])
}

let result: [String: Any] = [
    "beats": beats,
    "bars": bars,
    "sections": sections,
    "bpm": round(bpm * 10.0) / 10.0,
    "beatInterval": beatInterval,
    "beatCount": beats.count,
    "barCount": bars.count,
    "sectionCount": sections.count,
    "duration": totalDuration,
    "onsetCount": onsets.count,
    "filePath": filePath
]

outputJSON(result)
