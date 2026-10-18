// Original color bars + frame counter + 440 Hz tone. No capture, network, or ffmpeg.
import Foundation
import CoreGraphics
import AVFoundation
import CoreMedia
import CoreVideo
import AudioToolbox

struct FixtureError: Error, CustomStringConvertible {
    let description: String
}

func checked(_ status: OSStatus, _ label: String) throws {
    if status != noErr { throw FixtureError(description: "\(label): \(status)") }
}

func waitForInput(_ input: AVAssetWriterInput, _ writer: AVAssetWriter) throws {
    let deadline = Date().addingTimeInterval(10)
    while !input.isReadyForMoreMediaData {
        if writer.status == .failed || Date() > deadline {
            throw FixtureError(description: writer.error?.localizedDescription ?? "Writer readiness timeout")
        }
        Thread.sleep(forTimeInterval: 0.001)
    }
}

func main() throws {
    let args = CommandLine.arguments
    guard (args.count == 4 || args.count == 6), let scale = Int32(args[2]), let step = Int64(args[3]),
          (scale == 30 && step == 1) || (scale == 30000 && step == 1001) else {
        throw FixtureError(description: "Usage: generate_media OUTPUT.mov TIMESCALE FRAME_VALUE (30 1 or 30000 1001)")
    }
    let url = URL(fileURLWithPath: args[1])
    guard !FileManager.default.fileExists(atPath: url.path) else {
        throw FixtureError(description: "Refusing to replace existing media")
    }
    let frameCount = args.count == 6 ? Int(args[4]) ?? 0 : 90
    let channels = args.count == 6 ? Int(args[5]) ?? 0 : 1
    guard (90...1800).contains(frameCount), (1...2).contains(channels) else {
        throw FixtureError(description: "Frame count must be 90..1800; channels must be 1 or 2")
    }
    let width = 360, height = 640, sampleRate = 48000
    let videoURL = url.appendingPathExtension("video.mov")
    let audioURL = url.appendingPathExtension("tone.wav")
    guard !FileManager.default.fileExists(atPath: videoURL.path),
          !FileManager.default.fileExists(atPath: audioURL.path) else {
        throw FixtureError(description: "Refusing to replace intermediate media")
    }
    defer {
        try? FileManager.default.removeItem(at: videoURL)
        try? FileManager.default.removeItem(at: audioURL)
    }
    let writer = try AVAssetWriter(outputURL: videoURL, fileType: .mov)
    writer.movieTimeScale = scale
    let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 700000,
                                         AVVideoMaxKeyFrameIntervalKey: 30,
                                         AVVideoAllowFrameReorderingKey: false,
                                         AVVideoExpectedSourceFrameRateKey: Double(scale) / Double(step)]])
    video.mediaTimeScale = scale
    guard writer.canAdd(video) else { throw FixtureError(description: "Writer cannot add video") }
    writer.add(video)
    guard writer.startWriting() else { throw writer.error ?? FixtureError(description: "startWriting failed") }
    writer.startSession(atSourceTime: .zero)
    let colors: [[CGFloat]] = [[1,1,1], [1,1,0], [0,1,1], [0,1,0], [1,0,1], [1,0,0], [0,0,1], [0,0,0]]
    for frame in 0..<frameCount {
        try autoreleasepool {
            try waitForInput(video, writer)
            var pixel: CVPixelBuffer?
            try checked(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32ARGB,
                [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary,
                &pixel), "Pixel allocation")
            guard let pixel else { throw FixtureError(description: "No pixel buffer") }
            CVPixelBufferLockBaseAddress(pixel, [])
            defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
            guard let context = CGContext(data: CVPixelBufferGetBaseAddress(pixel), width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixel),
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else {
                throw FixtureError(description: "No bitmap context")
            }
            for (index, color) in colors.enumerated() {
                context.setFillColor(red: color[0], green: color[1], blue: color[2], alpha: 1)
                context.fill(CGRect(x: index * width / colors.count, y: 0,
                                    width: width / colors.count + 1, height: height))
            }
            context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: height / 2 - 48, width: width, height: 96))
            // Seven-segment digits avoid font and WindowServer dependencies in CI.
            let masks = [0x3f, 0x06, 0x5b, 0x4f, 0x66, 0x6d, 0x7d, 0x07, 0x7f, 0x6f]
            let segments = [CGRect(x: 5,y: 50,width: 24,height: 5), CGRect(x: 29,y: 28,width: 5,height: 22),
                            CGRect(x: 29,y: 5,width: 5,height: 22), CGRect(x: 5,y: 0,width: 24,height: 5),
                            CGRect(x: 0,y: 5,width: 5,height: 22), CGRect(x: 0,y: 28,width: 5,height: 22),
                            CGRect(x: 5,y: 25,width: 24,height: 5)]
            context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            for (index, digit) in [frame / 100, frame / 10 % 10, frame % 10].enumerated() {
                for (bit, segment) in segments.enumerated() where masks[digit] & (1 << bit) != 0 {
                    context.fill(segment.offsetBy(dx: CGFloat(112 + index * 46), dy: CGFloat(height / 2 - 28)))
                }
            }
            var description: CMVideoFormatDescription?
            try checked(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                imageBuffer: pixel, formatDescriptionOut: &description), "Video format")
            var timing = CMSampleTimingInfo(duration: CMTime(value: step, timescale: scale),
                presentationTimeStamp: CMTime(value: Int64(frame) * step, timescale: scale), decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            try checked(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                imageBuffer: pixel, formatDescription: description!, sampleTiming: &timing,
                sampleBufferOut: &sample), "Video sample")
            guard let sample, video.append(sample) else {
                throw writer.error ?? FixtureError(description: "Video append failed")
            }
        }
    }
    writer.endSession(atSourceTime: CMTime(value: Int64(frameCount) * step, timescale: scale))
    video.markAsFinished()
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    guard done.wait(timeout: .now() + 30) == .success, writer.status == .completed else {
        throw writer.error ?? FixtureError(description: "finishWriting failed")
    }
    // A separate PCM WAV and passthrough mux avoid interleaved writer backpressure.
    let audioSamples = Int(Int64(frameCount) * step * Int64(sampleRate) / Int64(scale))
    let byteCount = UInt32(audioSamples * 2 * channels)
    var wav = Data()
    func tag(_ value: String) { wav.append(value.data(using: .ascii)!) }
    func u16(_ value: UInt16) { var little = value.littleEndian; withUnsafeBytes(of: &little) { wav.append(contentsOf: $0) } }
    func u32(_ value: UInt32) { var little = value.littleEndian; withUnsafeBytes(of: &little) { wav.append(contentsOf: $0) } }
    tag("RIFF"); u32(36 + byteCount); tag("WAVEfmt "); u32(16); u16(1); u16(UInt16(channels))
    u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2 * channels)); u16(UInt16(2 * channels)); u16(16); tag("data"); u32(byteCount)
    for sample in 0..<audioSamples {
        let amplitude = sample % sampleRate < 2400 ? 0.35 : 0.12
        for channel in 0..<channels {
            let frequency = channel == 0 ? 440.0 : 660.0
            let value = Int16(sin(2 * .pi * frequency * Double(sample) / Double(sampleRate)) * 32767 * amplitude)
            u16(UInt16(bitPattern: value))
        }
    }
    try wav.write(to: audioURL, options: .withoutOverwriting)
    let composition = AVMutableComposition()
    let videoAsset = AVURLAsset(url: videoURL), audioAsset = AVURLAsset(url: audioURL)
    let range = CMTimeRange(start: .zero, duration: CMTime(value: Int64(frameCount) * step, timescale: scale))
    guard let videoSource = videoAsset.tracks(withMediaType: .video).first,
          let audioSource = audioAsset.tracks(withMediaType: .audio).first,
          let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
          let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
        throw FixtureError(description: "Cannot create fixture mux tracks")
    }
    try videoTrack.insertTimeRange(range, of: videoSource, at: .zero)
    try audioTrack.insertTimeRange(range, of: audioSource, at: .zero)
    guard let mux = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
        throw FixtureError(description: "Cannot create passthrough mux")
    }
    mux.outputURL = url
    mux.outputFileType = .mov
    mux.timeRange = range
    let muxDone = DispatchSemaphore(value: 0)
    mux.exportAsynchronously { muxDone.signal() }
    guard muxDone.wait(timeout: .now() + 30) == .success, mux.status == .completed else {
        throw mux.error ?? FixtureError(description: "Fixture mux failed")
    }
    print("Generated \(url.path): \(width)x\(height), \(frameCount) frames, \(scale)/\(step) fps, \(channels) channels")
}

do { try main() } catch {
    fputs("Fixture generation failed: \(error)\n", stderr)
    exit(1)
}
