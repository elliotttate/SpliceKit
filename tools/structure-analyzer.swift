#!/usr/bin/env swift
// structure-analyzer.swift -- Song structure analysis + beat detection.
//
// Analyzes any audio file to detect:
//   - Beats, bars, BPM (same onset algorithm as beat-detector.swift)
//   - Song structure: intro, verse, chorus, bridge, outro, drop
//   - Per-bar energy contour
//   - Drop points (sudden energy spikes)
//
// Uses energy contour + spectral features (via vDSP FFT) to segment
// the song into sections, then labels them by energy level, position,
// and repetition.
//
// Output: JSON with structure, beats, bars, bpm, energy, drops.
// Usage:  structure-analyzer <file_path> [sensitivity] [min_bpm] [max_bpm]

import Foundation
import AVFoundation
import Accelerate

// MARK: - Args

guard CommandLine.arguments.count >= 2 else {
    let err: [String: Any] = ["error": "Usage: structure-analyzer <file_path> [sensitivity] [min_bpm] [max_bpm]"]
    print(String(data: try! JSONSerialization.data(withJSONObject: err), encoding: .utf8)!)
    exit(1)
}

let filePath = CommandLine.arguments[1]
let sensitivity = CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2]) ?? 0.5 : 0.5
let minBPM = CommandLine.arguments.count > 3 ? Double(CommandLine.arguments[3]) ?? 60.0 : 60.0
let maxBPM = CommandLine.arguments.count > 4 ? Double(CommandLine.arguments[4]) ?? 200.0 : 200.0

func outputJSON(_ dict: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: dict, options: []),
       let str = String(data: data, encoding: .utf8) {
        print(str)
    }
}

func fail(_ msg: String) -> Never {
    outputJSON(["error": msg])
    exit(1)
}

// MARK: - Read Audio

let fileURL = URL(fileURLWithPath: filePath)
guard FileManager.default.fileExists(atPath: filePath) else { fail("File not found: \(filePath)") }

let asset = AVURLAsset(url: fileURL)
let totalDuration = CMTimeGetSeconds(asset.duration)
guard totalDuration > 0 else { fail("Could not determine audio duration") }
guard let reader = try? AVAssetReader(asset: asset) else { fail("Cannot create asset reader") }

let audioTracks = asset.tracks(withMediaType: .audio)
guard !audioTracks.isEmpty else { fail("No audio tracks in file") }

let sampleRate: Double = 44100.0
let outputSettings: [String: Any] = [
    AVFormatIDKey: kAudioFormatLinearPCM,
    AVLinearPCMBitDepthKey: 32,
    AVLinearPCMIsFloatKey: true,
    AVLinearPCMIsBigEndianKey: false,
    AVLinearPCMIsNonInterleaved: false,
    AVSampleRateKey: sampleRate,
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
    CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                totalLengthOut: &length, dataPointerOut: &dataPointer)
    if let ptr = dataPointer, length > 0 {
        pcmData.append(UnsafeBufferPointer(
            start: UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt8.self), count: length))
    }
}
guard !pcmData.isEmpty else { fail("Could not read audio samples") }

let sampleCount = pcmData.count / MemoryLayout<Float>.size
let samples: [Float] = pcmData.withUnsafeBytes { ptr in
    Array(ptr.bindMemory(to: Float.self))
}

// MARK: - Beat Detection (same algorithm as beat-detector.swift)

let hopSize = 512
let windowSize = 1024
let hopDuration = Double(hopSize) / sampleRate

let numFrames = (sampleCount > windowSize) ? (sampleCount - windowSize) / hopSize : 0
guard numFrames >= 10 else { fail("Audio too short for analysis") }

// RMS energy per hop window
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

// Local average for adaptive threshold
let avgWindow = max(4, Int(0.5 / hopDuration))
var localAvg = [Float](repeating: 0, count: numFrames)
for i in 0..<numFrames {
    let start = max(0, i - avgWindow)
    let end = min(numFrames, i + avgWindow)
    var sum: Float = 0
    for j in start..<end { sum += energy[j] }
    localAvg[i] = sum / Float(end - start)
}

// Onset detection
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
guard onsets.count >= 4 else { fail("Could not detect enough beats in audio") }

// Tempo estimation
var intervals = [Double]()
for i in 1..<onsets.count {
    let interval = onsets[i] - onsets[i-1]
    if interval > 0.1 && interval < 2.0 { intervals.append(interval) }
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

// Grid alignment
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

// Beat grid
var beats = [Double]()
var t = bestOffset
while t < totalDuration { beats.append(t); t += beatInterval }

// Bars (every 4 beats)
var bars = [Double]()
for i in stride(from: 0, to: beats.count, by: 4) { bars.append(beats[i]) }

guard bars.count >= 2 else { fail("Audio too short for structure analysis") }

// MARK: - Per-Bar Energy Contour

// Compute RMS energy for each bar-length window
var barEnergy = [Float](repeating: 0, count: bars.count)
for bi in 0..<bars.count {
    let barStart = Int(bars[bi] * sampleRate)
    let barEnd: Int
    if bi + 1 < bars.count {
        barEnd = min(sampleCount, Int(bars[bi + 1] * sampleRate))
    } else {
        barEnd = sampleCount
    }
    guard barEnd > barStart else { continue }
    let count = barEnd - barStart
    var sum: Float = 0
    for j in barStart..<barEnd where j < sampleCount {
        sum += samples[j] * samples[j]
    }
    barEnergy[bi] = sqrtf(sum / Float(count))
}

// Normalize bar energy to 0..1
let maxBarEnergy = barEnergy.max() ?? 1.0
let minBarEnergy = barEnergy.min() ?? 0.0
let energyRange = maxBarEnergy - minBarEnergy
var normEnergy = [Float](repeating: 0, count: bars.count)
if energyRange > 0 {
    for i in 0..<bars.count {
        normEnergy[i] = (barEnergy[i] - minBarEnergy) / energyRange
    }
} else {
    for i in 0..<bars.count { normEnergy[i] = 0.5 }
}

// MARK: - Spectral Centroid per Bar (via vDSP FFT)

let fftSize = 2048
let log2n = vDSP_Length(log2(Double(fftSize)))
guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
    fail("Failed to create FFT setup")
}

// Hann window
var hannWindow = [Float](repeating: 0, count: fftSize)
vDSP_hann_window(&hannWindow, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

func spectralCentroid(startSample: Int, endSample: Int) -> Float {
    // Take an FFT of the middle chunk of this range
    let midpoint = (startSample + endSample) / 2
    let fftStart = max(0, midpoint - fftSize / 2)
    guard fftStart + fftSize <= sampleCount else { return 0 }

    // Window the samples
    var windowed = [Float](repeating: 0, count: fftSize)
    for i in 0..<fftSize {
        windowed[i] = samples[fftStart + i] * hannWindow[i]
    }

    // Pack into split complex
    var realp = [Float](repeating: 0, count: fftSize / 2)
    var imagp = [Float](repeating: 0, count: fftSize / 2)
    windowed.withUnsafeBufferPointer { buf in
        buf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { cPtr in
            var split = DSPSplitComplex(realp: &realp, imagp: &imagp)
            vDSP_ctoz(cPtr, 2, &split, 1, vDSP_Length(fftSize / 2))
        }
    }

    // Forward FFT
    var split = DSPSplitComplex(realp: &realp, imagp: &imagp)
    vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))

    // Magnitude spectrum
    var magnitudes = [Float](repeating: 0, count: fftSize / 2)
    vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))

    // Spectral centroid: weighted average of frequencies
    var weightedSum: Float = 0
    var totalMag: Float = 0
    for bin in 1..<(fftSize / 2) {
        let freq = Float(bin) * Float(sampleRate) / Float(fftSize)
        weightedSum += freq * magnitudes[bin]
        totalMag += magnitudes[bin]
    }
    return totalMag > 0 ? weightedSum / totalMag : 0
}

// Compute spectral centroid per bar
var barCentroid = [Float](repeating: 0, count: bars.count)
for bi in 0..<bars.count {
    let barStart = Int(bars[bi] * sampleRate)
    let barEnd: Int
    if bi + 1 < bars.count {
        barEnd = min(sampleCount, Int(bars[bi + 1] * sampleRate))
    } else {
        barEnd = sampleCount
    }
    barCentroid[bi] = spectralCentroid(startSample: barStart, endSample: barEnd)
}

// Normalize centroid to 0..1
let maxCentroid = barCentroid.max() ?? 1.0
let minCentroid = barCentroid.min() ?? 0.0
let centroidRange = maxCentroid - minCentroid
var normCentroid = [Float](repeating: 0, count: bars.count)
if centroidRange > 0 {
    for i in 0..<bars.count {
        normCentroid[i] = (barCentroid[i] - minCentroid) / centroidRange
    }
}

vDSP_destroy_fftsetup(fftSetup)

// MARK: - Feature Vector per Bar (energy + centroid)

struct BarFeatures {
    var energy: Float
    var centroid: Float

    func distance(to other: BarFeatures) -> Float {
        let de = energy - other.energy
        let dc = centroid - other.centroid
        return sqrtf(de * de + dc * dc)
    }
}

var barFeatures = (0..<bars.count).map { BarFeatures(energy: normEnergy[$0], centroid: normCentroid[$0]) }

// MARK: - Boundary Detection (novelty curve)

// Compute feature distance between consecutive bars
var novelty = [Float](repeating: 0, count: bars.count)
for i in 1..<bars.count {
    novelty[i] = barFeatures[i].distance(to: barFeatures[i - 1])
}

// Adaptive threshold: mean + 0.8 * std of novelty values
let noveltySlice = Array(novelty[1...])
let noveltyMean = noveltySlice.reduce(0, +) / Float(noveltySlice.count)
let noveltyVariance = noveltySlice.reduce(0.0 as Float) { $0 + ($1 - noveltyMean) * ($1 - noveltyMean) } / Float(noveltySlice.count)
let noveltyStd = sqrtf(noveltyVariance)
let boundaryThreshold = noveltyMean + 0.8 * noveltyStd

// Find boundary bars (where novelty exceeds threshold)
var boundaries = [0]  // first bar is always a boundary
let minSectionBars = 4 // minimum section length

for i in 1..<bars.count {
    if novelty[i] > boundaryThreshold {
        let lastBoundary = boundaries.last!
        if (i - lastBoundary) >= minSectionBars {
            boundaries.append(i)
        }
    }
}

// Ensure we have at least 2 sections for interesting structure
// If only 1 boundary (bar 0), try a lower threshold
if boundaries.count < 2 {
    let lowerThreshold = noveltyMean + 0.3 * noveltyStd
    boundaries = [0]
    for i in 1..<bars.count {
        if novelty[i] > lowerThreshold {
            let lastBoundary = boundaries.last!
            if (i - lastBoundary) >= minSectionBars {
                boundaries.append(i)
            }
        }
    }
}

// If still only 1 section, split by energy quartiles
if boundaries.count < 2 && bars.count >= 8 {
    let quarterLen = bars.count / 4
    boundaries = [0]
    for q in 1..<4 {
        boundaries.append(q * quarterLen)
    }
}

// MARK: - Build Sections

struct Section {
    var startBar: Int
    var endBar: Int          // exclusive
    var startTime: Double
    var endTime: Double
    var meanEnergy: Float
    var meanCentroid: Float
    var label: String = ""
    var group: Int = -1      // repetition group
}

var sections = [Section]()
for si in 0..<boundaries.count {
    let startBar = boundaries[si]
    let endBar = (si + 1 < boundaries.count) ? boundaries[si + 1] : bars.count
    let startTime = bars[startBar]
    let endTime = (endBar < bars.count) ? bars[endBar] : totalDuration

    // Mean features across the section
    var eSum: Float = 0, cSum: Float = 0
    for bi in startBar..<endBar {
        eSum += normEnergy[bi]
        cSum += normCentroid[bi]
    }
    let count = Float(endBar - startBar)
    sections.append(Section(
        startBar: startBar, endBar: endBar,
        startTime: startTime, endTime: endTime,
        meanEnergy: eSum / count, meanCentroid: cSum / count
    ))
}

// MARK: - Repetition Detection (group similar sections)

// Cosine similarity between section feature vectors
func sectionSimilarity(_ a: Section, _ b: Section) -> Float {
    let dot = a.meanEnergy * b.meanEnergy + a.meanCentroid * b.meanCentroid
    let magA = sqrtf(a.meanEnergy * a.meanEnergy + a.meanCentroid * a.meanCentroid)
    let magB = sqrtf(b.meanEnergy * b.meanEnergy + b.meanCentroid * b.meanCentroid)
    guard magA > 0 && magB > 0 else { return 0 }
    return dot / (magA * magB)
}

// Simple greedy clustering: assign each section to first matching group
let similarityThreshold: Float = 0.95
var groupCount = 0
var groupRepresentative = [Int: Section]()

for i in 0..<sections.count {
    var assigned = false
    for g in 0..<groupCount {
        if let rep = groupRepresentative[g],
           sectionSimilarity(sections[i], rep) >= similarityThreshold {
            sections[i].group = g
            assigned = true
            break
        }
    }
    if !assigned {
        sections[i].group = groupCount
        groupRepresentative[groupCount] = sections[i]
        groupCount += 1
    }
}

// MARK: - Label Sections

// Compute mean energy per group
var groupEnergies = [Int: [Float]]()
for s in sections {
    groupEnergies[s.group, default: []].append(s.meanEnergy)
}
var groupMeanEnergy = [Int: Float]()
for (g, energies) in groupEnergies {
    groupMeanEnergy[g] = energies.reduce(0, +) / Float(energies.count)
}

// Sort groups by mean energy (highest first)
let sortedGroups = groupMeanEnergy.sorted { $0.value > $1.value }

// Determine overall energy threshold for high/low classification
let overallMeanEnergy = normEnergy.reduce(0, +) / Float(normEnergy.count)

// Labeling heuristics
let highEnergyGroups = sortedGroups.filter { $0.value > overallMeanEnergy + 0.1 }
let lowEnergyGroups = sortedGroups.filter { $0.value <= overallMeanEnergy - 0.1 }

// Track which groups get labeled as what
var groupLabels = [Int: String]()

// Highest energy recurring group → chorus
if let chorusGroup = highEnergyGroups.first {
    let count = groupEnergies[chorusGroup.key]?.count ?? 0
    if count >= 2 || highEnergyGroups.count == 1 {
        groupLabels[chorusGroup.key] = "chorus"
    }
}

// Second-highest (or lower) recurring group → verse
for g in sortedGroups {
    if groupLabels[g.key] != nil { continue }
    let count = groupEnergies[g.key]?.count ?? 0
    if count >= 2 {
        groupLabels[g.key] = "verse"
        break
    }
}

// Now assign labels to each section
var chorusCount = 0
var verseCount = 0
var bridgeCount = 0

for i in 0..<sections.count {
    let s = sections[i]
    let isFirst = (i == 0)
    let isLast = (i == sections.count - 1)
    let barCount = s.endBar - s.startBar
    let duration = s.endTime - s.startTime

    // Intro: first section, relatively low energy or short
    if isFirst && (s.meanEnergy < overallMeanEnergy || barCount <= 4) {
        sections[i].label = "intro"
        continue
    }

    // Outro: last section, relatively low energy or short
    if isLast && (s.meanEnergy < overallMeanEnergy || barCount <= 4) {
        sections[i].label = "outro"
        continue
    }

    // Use group label if available
    if let gLabel = groupLabels[s.group] {
        if gLabel == "chorus" {
            chorusCount += 1
            sections[i].label = "chorus\(chorusCount)"
        } else if gLabel == "verse" {
            verseCount += 1
            sections[i].label = "verse\(verseCount)"
        }
        continue
    }

    // Ungrouped high-energy section → chorus (or labeled by energy)
    if s.meanEnergy > overallMeanEnergy + 0.15 {
        chorusCount += 1
        sections[i].label = "chorus\(chorusCount)"
        continue
    }

    // Ungrouped medium-energy section → verse or bridge
    // Bridge: appears once and sits between chorus sections
    let appearsOnce = groupEnergies[s.group]?.count == 1
    if appearsOnce && i > 0 && i < sections.count - 1 {
        bridgeCount += 1
        sections[i].label = bridgeCount == 1 ? "bridge" : "bridge\(bridgeCount)"
    } else {
        verseCount += 1
        sections[i].label = "verse\(verseCount)"
    }
}

// Fix: if no labels got "chorus" but we have sections, use energy ranking
if !sections.contains(where: { $0.label.hasPrefix("chorus") }) && sections.count >= 3 {
    // Find the highest energy section(s) and call them chorus
    let energySorted = sections.enumerated().sorted { $0.element.meanEnergy > $1.element.meanEnergy }
    chorusCount = 0
    for (idx, _) in energySorted.prefix(max(1, sections.count / 3)) {
        if !sections[idx].label.hasPrefix("intro") && !sections[idx].label.hasPrefix("outro") {
            chorusCount += 1
            sections[idx].label = "chorus\(chorusCount)"
        }
    }
}

// MARK: - Drop Detection

// A "drop" is where energy jumps significantly from one bar to the next
var drops = [Double]()
for i in 1..<bars.count {
    let prev = normEnergy[max(0, i - 2)..<i].reduce(0, +) / Float(min(i, 2))
    let curr = normEnergy[i]
    // Drop: current bar is > 2x the average of previous 2 bars, and previous was below mean
    if curr > prev * 2.0 && prev < overallMeanEnergy * 0.7 && curr > overallMeanEnergy {
        drops.append(bars[i])
    }
}

// MARK: - Downbeat Strengths

// Estimate onset strength per beat using the energy curve
var beatStrengths = [[String: Any]]()
for bi in 0..<beats.count {
    let beatTime = beats[bi]
    let frameIdx = Int(beatTime / hopDuration)
    let strength: Float
    if frameIdx >= 0 && frameIdx < numFrames {
        strength = min(1.0, energy[frameIdx] / (maxBarEnergy > 0 ? maxBarEnergy : 1.0))
    } else {
        strength = 0
    }
    let positionInBar = bi % 4  // 0=downbeat, 1,2,3
    beatStrengths.append([
        "time": round(beatTime * 1000) / 1000,
        "strength": round(Double(strength) * 1000) / 1000,
        "position": positionInBar + 1
    ])
}

// MARK: - Build Output

var structureOut = [[String: Any]]()
for s in sections {
    structureOut.append([
        "label": s.label,
        "start": round(s.startTime * 1000) / 1000,
        "end": round(s.endTime * 1000) / 1000,
        "duration": round((s.endTime - s.startTime) * 1000) / 1000,
        "bars": s.endBar - s.startBar,
        "energy": round(Double(s.meanEnergy) * 1000) / 1000
    ])
}

var energyContour = [[String: Any]]()
for i in 0..<bars.count {
    energyContour.append([
        "bar": i,
        "time": round(bars[i] * 1000) / 1000,
        "energy": round(Double(normEnergy[i]) * 1000) / 1000
    ])
}

let result: [String: Any] = [
    "structure": structureOut,
    "beats": beats.map { round($0 * 1000) / 1000 },
    "bars": bars.map { round($0 * 1000) / 1000 },
    "bpm": round(bpm * 10) / 10,
    "beatInterval": round(beatInterval * 10000) / 10000,
    "beatCount": beats.count,
    "barCount": bars.count,
    "sectionCount": sections.count,
    "duration": round(totalDuration * 1000) / 1000,
    "drops": drops.map { round($0 * 1000) / 1000 },
    "beatStrengths": beatStrengths,
    "energyContour": energyContour,
    "filePath": filePath
]

outputJSON(result)
