import Foundation
import SwiftUI

/// State for a single mixer fader.
struct FaderState: Identifiable {
    let id: Int // 0-9
    var clipHandle: String?
    var effectStackHandle: String?
    var volumeChannelHandle: String?
    var clipName: String = ""
    var lane: Int = 0
    var volumeDB: Double = -Double.infinity
    var volumeLinear: Double = 0
    var role: String?
    var roleColorHex: String?
    var meterPeak: Double = 0
    var isActive: Bool = false
    var isPlaying: Bool = false
    var isSoloed: Bool = false
    var isSoloMuted: Bool = false
    var isMuted: Bool = false
    var isMuteMixed: Bool = false
    var isDragging: Bool = false
    var minDB: Double = -96
    var maxDB: Double = 12

    static func inactive(index: Int) -> FaderState {
        FaderState(id: index)
    }
}

/// Main model driving the mixer UI. Polls SpliceKit for clip state at the playhead.
@MainActor
class MixerModel: ObservableObject {
    @Published var faders: [FaderState] = (0..<10).map { FaderState.inactive(index: $0) }
    @Published var isConnected = false
    @Published var lastError: String?
    @Published var playheadSeconds = 0.0
    @Published var frameRate = 0.0
    @Published var isTransportPlaying = false

    let bridge = SpliceKitBridge()
    private var pollTimer: Timer?

    func start() {
        bridge.connect()
        startPolling()
    }

    func stop() {
        stopPolling()
        bridge.disconnect()
    }

    func startPolling() {
        stopPolling()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.poll()
            }
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Polling

    private func poll() async {
        guard bridge.isConnected else {
            if isConnected {
                isConnected = false
            }
            bridge.connect()
            return
        }
        isConnected = true

        do {
            let result = try await bridge.call("mixer.getState")
            if let error = result["error"] as? String {
                lastError = error
                clearFaders()
                return
            }

            lastError = nil
            updateFaders(from: result)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func updateFaders(from result: [String: Any]) {
        guard let faderData = result["faders"] as? [[String: Any]] else { return }

        playheadSeconds = result["playheadSeconds"] as? Double ?? 0
        frameRate = result["frameRate"] as? Double ?? 0
        isTransportPlaying = result["isPlaying"] as? Bool ?? false

        var newFaders = (0..<10).map { FaderState.inactive(index: $0) }

        for dict in faderData {
            guard let index = dict["index"] as? Int, index < 10 else { continue }

            if faders[index].isDragging { continue }

            var fader = FaderState(id: index)
            fader.clipHandle = dict["clipHandle"] as? String
            fader.effectStackHandle = dict["effectStackHandle"] as? String
            fader.volumeChannelHandle = dict["volumeChannelHandle"] as? String
            fader.clipName = dict["name"] as? String ?? ""
            fader.lane = dict["lane"] as? Int ?? 0
            fader.role = dict["role"] as? String
            fader.roleColorHex = dict["roleColor"] as? String
            fader.meterPeak = dict["meterPeak"] as? Double ?? 0
            fader.isActive = true
            fader.isPlaying = dict["playing"] as? Bool ?? false
            fader.isSoloed = dict["soloed"] as? Bool ?? false
            fader.isSoloMuted = dict["soloMuted"] as? Bool ?? false
            fader.isMuted = dict["muted"] as? Bool ?? false
            fader.isMuteMixed = dict["muteMixed"] as? Bool ?? false
            fader.minDB = dict["minDB"] as? Double ?? -96
            fader.maxDB = dict["maxDB"] as? Double ?? 12

            if let db = dict["volumeDB"] as? Double {
                fader.volumeDB = db
            }
            if let linear = dict["volumeLinear"] as? Double {
                fader.volumeLinear = linear
            }

            newFaders[index] = fader
        }

        for index in 0..<10 where faders[index].isDragging {
            newFaders[index] = faders[index]
        }

        faders = newFaders
    }

    private func clearFaders() {
        faders = (0..<10).map { FaderState.inactive(index: $0) }
        playheadSeconds = 0
        frameRate = 0
        isTransportPlaying = false
    }

    // MARK: - Volume Control

    func beginVolumeChange(faderIndex: Int) async {
        guard faders[faderIndex].isActive,
              let effectStackHandle = faders[faderIndex].effectStackHandle else { return }

        faders[faderIndex].isDragging = true

        do {
            _ = try await bridge.call("mixer.volumeBegin", params: [
                "effectStackHandle": effectStackHandle
            ])
        } catch {
            lastError = error.localizedDescription
        }
    }

    func setVolume(faderIndex: Int, db: Double) async {
        guard faders[faderIndex].isActive,
              let handle = faders[faderIndex].volumeChannelHandle else { return }

        faders[faderIndex].volumeDB = db
        faders[faderIndex].volumeLinear = db <= -144 ? 0 : pow(10.0, db / 20.0)

        do {
            _ = try await bridge.call("mixer.setVolume", params: [
                "handle": handle,
                "volumeDB": db
            ])
        } catch {
            lastError = error.localizedDescription
        }
    }

    func endVolumeChange(faderIndex: Int) async {
        guard let effectStackHandle = faders[faderIndex].effectStackHandle else { return }

        faders[faderIndex].isDragging = false

        do {
            _ = try await bridge.call("mixer.volumeEnd", params: [
                "effectStackHandle": effectStackHandle
            ])
        } catch {
            lastError = error.localizedDescription
        }
    }

    func toggleSolo(faderIndex: Int) async {
        guard faders.indices.contains(faderIndex), faders[faderIndex].isActive else { return }

        do {
            _ = try await bridge.call("mixer.setSolo", params: [
                "index": faderIndex,
                "mode": "toggle"
            ])
            await poll()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func toggleMute(faderIndex: Int) async {
        guard faders.indices.contains(faderIndex), faders[faderIndex].isActive else { return }

        do {
            _ = try await bridge.call("mixer.setMute", params: [
                "index": faderIndex,
                "mode": "toggle"
            ])
            await poll()
        } catch {
            lastError = error.localizedDescription
        }
    }
}
