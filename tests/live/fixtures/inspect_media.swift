// Independent AVFoundation readback of generated fixtures; no FCP required.
import Foundation
import AVFoundation
import CoreMedia

func inspect(_ url: URL) throws -> [String: Any] {
    let asset = AVURLAsset(url: url)
    guard let video = asset.tracks(withMediaType: .video).first,
          let audio = asset.tracks(withMediaType: .audio).first else {
        throw NSError(domain: "FixtureReadback", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing video/audio track"])
    }
    let videoReader = try AVAssetReader(asset: asset)
    let videoOutput = AVAssetReaderTrackOutput(track: video, outputSettings: nil)
    videoReader.add(videoOutput)
    guard videoReader.startReading() else { throw videoReader.error! }
    var positions: [CMTime] = []
    while let sample = videoOutput.copyNextSampleBuffer() {
        if CMSampleBufferGetNumSamples(sample) == 0 { continue }
        positions.append(CMSampleBufferGetPresentationTimeStamp(sample))
    }
    guard videoReader.status == .completed else { throw videoReader.error! }
    positions.sort { CMTimeCompare($0, $1) < 0 }
    var durations: [[String: Int64]] = []
    for index in 1..<positions.count {
        let time = CMTimeSubtract(positions[index], positions[index - 1])
        durations.append(["value": time.value, "timescale": Int64(time.timescale)])
    }
    let audioReader = try AVAssetReader(asset: asset)
    let audioOutput = AVAssetReaderTrackOutput(track: audio, outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false])
    audioReader.add(audioOutput)
    guard audioReader.startReading() else { throw audioReader.error! }
    var squares = 0.0
    var sampleCount = 0
    while let sample = audioOutput.copyNextSampleBuffer() {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
        let length = CMBlockBufferGetDataLength(block)
        var values = [Int16](repeating: 0, count: length / 2)
        let status = values.withUnsafeMutableBytes { bytes in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: bytes.baseAddress!)
        }
        guard status == noErr else { throw NSError(domain: "FixtureReadback", code: Int(status)) }
        for value in values { squares += pow(Double(value) / 32768, 2) }
        sampleCount += values.count
    }
    guard audioReader.status == .completed else { throw audioReader.error! }
    let audioDescription = audio.formatDescriptions.first as! CMAudioFormatDescription
    let channelCount = CMAudioFormatDescriptionGetStreamBasicDescription(audioDescription)!.pointee.mChannelsPerFrame
    return ["width": Int(video.naturalSize.width), "height": Int(video.naturalSize.height), "audio_channels": Int(channelCount),
            "frame_count": positions.count, "frame_intervals": durations,
            "first_pts": ["value": positions.first?.value ?? -1,
                          "timescale": Int64(positions.first?.timescale ?? 1)],
            "duration": ["value": video.timeRange.duration.value,
                         "timescale": Int64(video.timeRange.duration.timescale)],
            "audio_samples": sampleCount, "audio_rms": sampleCount > 0 ? sqrt(squares / Double(sampleCount)) : 0]
}

do {
    guard CommandLine.arguments.count == 2 else { throw NSError(domain: "Usage: inspect_media FILE.mov", code: 2) }
    let result = try inspect(URL(fileURLWithPath: CommandLine.arguments[1]))
    let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
} catch {
    fputs("Fixture readback failed: \(error)\n", stderr)
    exit(1)
}
