import SwiftUI

struct MixerView: View {
    @ObservedObject var model: MixerModel

    var body: some View {
        ZStack {
            MixerBackdrop()

            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(model.faders) { fader in
                        MixerChannelStrip(
                            fader: fader,
                            isConnected: model.isConnected,
                            onDragStart: {
                                Task {
                                    await model.beginVolumeChange(faderIndex: fader.id)
                                }
                            },
                            onDragChange: { db in
                                Task {
                                    await model.setVolume(faderIndex: fader.id, db: db)
                                }
                            },
                            onDragEnd: {
                                Task {
                                    await model.endVolumeChange(faderIndex: fader.id)
                                }
                            },
                            onToggleSolo: {
                                Task {
                                    await model.toggleSolo(faderIndex: fader.id)
                                }
                            },
                            onToggleMute: {
                                Task {
                                    await model.toggleMute(faderIndex: fader.id)
                                }
                            }
                        )

                        if fader.id != model.faders.count - 1 {
                            Rectangle()
                                .fill(.white.opacity(0.08))
                                .frame(width: 1)
                                .padding(.vertical, 18)
                        }
                    }
                }
                .padding(8)

                HStack(spacing: 12) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(model.isConnected ? .green : .red)
                            .frame(width: 8, height: 8)

                        Text(model.isConnected ? "Connected to SpliceKit bridge" : "Disconnected from SpliceKit bridge")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.32))
                            .lineLimit(1)
                    }

                    if let error = model.lastError {
                        Text(error)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.red.opacity(0.8))
                            .lineLimit(1)
                    }

                    Spacer()

                    Label(model.isTransportPlaying ? "Playing" : "Stopped",
                          systemImage: model.isTransportPlaying ? "play.fill" : "pause.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.32))

                    Text(timecodeString(seconds: model.playheadSeconds, frameRate: model.frameRate))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.34))

                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 18, weight: .light))
                        .foregroundStyle(.white.opacity(0.18))
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 16)
            }
            .frame(minWidth: 1008, minHeight: 688)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.22, green: 0.22, blue: 0.24),
                                Color(red: 0.16, green: 0.16, blue: 0.18)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(.white.opacity(0.09), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.35), radius: 30, y: 20)
            )
        }
        .frame(minWidth: 1036, minHeight: 742)
    }

    private func timecodeString(seconds: Double, frameRate: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--:--:--" }
        let wholeSeconds = Int(seconds)
        let hours = wholeSeconds / 3600
        let minutes = (wholeSeconds / 60) % 60
        let secs = wholeSeconds % 60
        let frames = frameRate > 0
            ? max(0, Int(((seconds - floor(seconds)) * frameRate).rounded(.down)))
            : 0
        return String(format: "%02d:%02d:%02d:%02d", hours, minutes, secs, frames)
    }
}

private struct MixerBackdrop: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.09, green: 0.09, blue: 0.11),
                Color(red: 0.13, green: 0.12, blue: 0.16)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay {
            Circle()
                .fill(.white.opacity(0.03))
                .frame(width: 520, height: 520)
                .blur(radius: 100)
                .offset(x: -160, y: -180)
        }
        .ignoresSafeArea()
    }
}

private struct MixerChannelStrip: View {
    let fader: FaderState
    let isConnected: Bool
    let onDragStart: () -> Void
    let onDragChange: (Double) -> Void
    let onDragEnd: () -> Void
    let onToggleSolo: () -> Void
    let onToggleMute: () -> Void

    private var palette: MixerStripPalette {
        MixerStripPalette.make(for: fader)
    }

    private var isDimmed: Bool {
        !fader.isActive || !fader.isPlaying || fader.isSoloMuted || fader.isMuted
    }

    var body: some View {
        VStack(spacing: 0) {
            displayPanel
            statusGrid
            faderSection
            labelSection
        }
        .frame(width: 92)
        .padding(.horizontal, 2)
        .padding(.vertical, 10)
        .background(stripBackground)
    }

    private var stripBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(
                LinearGradient(
                    colors: palette.stripBackground,
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        palette.edgeColor.opacity(fader.isActive ? (isDimmed ? 0.14 : 0.28) : 0.12),
                        lineWidth: 1
                    )
            )
            .shadow(color: palette.glow.opacity(isDimmed ? 0.08 : 0.22), radius: 18, y: 8)
    }

    private var displayPanel: some View {
        VStack(spacing: 4) {
            Text("\(fader.id + 1)")
                .font(.system(size: 28, weight: .regular, design: .rounded))
                .foregroundStyle(fader.isActive ? palette.displayText : .white.opacity(0.24))

            Text(displayValue)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(fader.isActive ? palette.secondaryText : .white.opacity(0.18))
        }
        .frame(height: 106)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: palette.displayBackground,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(palette.edgeColor.opacity(fader.isActive ? 0.32 : 0.12), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.34), radius: 10, y: 6)
        )
        .padding(.horizontal, 4)
        .padding(.top, 4)
    }

    private var statusGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 8), count: 2), spacing: 8) {
            MixerStatusTile(title: "ON", isOn: fader.isActive, accent: palette.accent, isDimmed: !fader.isActive)
            MixerStatusTile(title: "LIVE", isOn: fader.isPlaying, accent: .green.opacity(0.9), isDimmed: !fader.isPlaying)
            MixerStatusTile(title: "SIG", isOn: fader.meterPeak > 0.04, accent: .cyan.opacity(0.9), isDimmed: fader.meterPeak <= 0.04)
            MixerStatusButton(title: fader.isMuteMixed ? "MIX" : "MUTE",
                              isOn: fader.isMuted || fader.isMuteMixed,
                              accent: fader.isMuteMixed ? .orange : .red,
                              isEnabled: fader.isActive,
                              action: onToggleMute)
            MixerStatusButton(title: "SOLO",
                              isOn: fader.isSoloed,
                              accent: .yellow,
                              isEnabled: fader.isActive,
                              action: onToggleSolo)
            MixerStatusTile(title: laneLabel, isOn: fader.isActive, accent: palette.accent.opacity(isConnected ? 0.92 : 0.55), isDimmed: !fader.isActive)
        }
        .padding(.top, 14)
        .padding(.bottom, 18)
    }

    private var faderSection: some View {
        HStack(alignment: .bottom, spacing: 10) {
            MixerSurfaceFader(
                valueDB: fader.volumeDB,
                minDB: fader.minDB,
                maxDB: fader.maxDB,
                accent: palette.accent,
                isEnabled: fader.isActive,
                isDimmed: isDimmed,
                onDragStart: onDragStart,
                onDragChange: onDragChange,
                onDragEnd: onDragEnd
            )

            MixerLevelMeter(
                level: fader.meterPeak,
                accent: palette.accent,
                isDimmed: isDimmed
            )
        }
        .frame(height: 300)
    }

    private var labelSection: some View {
        VStack(spacing: 7) {
            Image(systemName: palette.symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(palette.accent.opacity(fader.isActive ? 0.92 : 0.28))

            Text(titleText)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(fader.isActive ? palette.secondaryText : .white.opacity(0.24))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(minHeight: 28)

            if !subtitleText.isEmpty {
                Text(subtitleText)
                    .font(.system(size: 8.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.72))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(.black.opacity(0.38))
                    )
                    .padding(.top, 2)
            } else {
                Spacer()
                    .frame(height: 22)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }

    private var displayValue: String {
        guard fader.isActive else { return "--" }
        if fader.volumeDB <= fader.minDB + 0.1 { return "-inf dB" }
        return "\(fader.volumeDB.rounded(toPlaces: 1).formatted(.number.precision(.fractionLength(1)))) dB"
    }

    private var titleText: String {
        guard let role = fader.role, !role.isEmpty else { return "Unused" }
        return role.replacingOccurrences(of: ".", with: "\n")
    }

    private var subtitleText: String {
        guard fader.isActive, !fader.clipName.isEmpty else { return "" }
        return fader.clipName
    }

    private var laneLabel: String {
        if !fader.isActive { return "--" }
        return fader.lane == 0 ? "PRI" : "L\(fader.lane)"
    }
}

private struct MixerStatusTile: View {
    let title: String
    let isOn: Bool
    let accent: Color
    let isDimmed: Bool

    var body: some View {
        Text(title)
            .font(.system(size: title.count > 2 ? 8.5 : 10, weight: .semibold, design: .rounded))
            .frame(width: 34, height: 28)
            .foregroundStyle(isOn ? accent.opacity(0.98) : .white.opacity(isDimmed ? 0.24 : 0.58))
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(isOn ? 0.22 : 0.14),
                                Color.black.opacity(isOn ? 0.34 : 0.25)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isOn ? accent.opacity(0.9) : .white.opacity(0.12), lineWidth: 1)
            )
            .overlay(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(accent.opacity(isOn ? 0.16 : 0))
                    .frame(height: 10)
                    .blur(radius: 6)
                    .padding(.horizontal, 4)
            }
            .shadow(color: .black.opacity(0.35), radius: 5, y: 3)
    }
}

private struct MixerStatusButton: View {
    let title: String
    let isOn: Bool
    let accent: Color
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: title.count > 3 ? 7.8 : 8.5, weight: .semibold, design: .rounded))
                .frame(width: 34, height: 28)
                .foregroundStyle(isOn ? accent.opacity(0.98) : .white.opacity(isEnabled ? 0.58 : 0.24))
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(isOn ? 0.22 : 0.14),
                                    Color.black.opacity(isOn ? 0.34 : 0.25)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(isOn ? accent.opacity(0.9) : .white.opacity(0.12), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

private struct MixerSurfaceFader: View {
    let valueDB: Double
    let minDB: Double
    let maxDB: Double
    let accent: Color
    let isEnabled: Bool
    let isDimmed: Bool
    let onDragStart: () -> Void
    let onDragChange: (Double) -> Void
    let onDragEnd: () -> Void

    @State private var presentedValue = 0.0
    @State private var isDragging = false

    private let knobHeight: CGFloat = 44

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let normalized = dbToNormalized(presentedValue, minDB: minDB, maxDB: maxDB)
            let usableHeight = max(size.height - knobHeight, 1)
            let yPosition = (1 - normalized) * usableHeight

            ZStack(alignment: .top) {
                tickMarks(height: size.height)

                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.black.opacity(0.32), Color.white.opacity(0.05), Color.black.opacity(0.3)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: 8)
                    .frame(maxHeight: .infinity)

                Capsule(style: .continuous)
                    .fill(accent.opacity(isEnabled ? (isDimmed ? 0.22 : 0.75) : 0.12))
                    .frame(width: 4)
                    .frame(height: max(18, usableHeight - yPosition + knobHeight * 0.16))
                    .offset(y: yPosition + knobHeight * 0.34)

                knob
                    .offset(y: yPosition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        guard isEnabled else { return }
                        if !isDragging {
                            isDragging = true
                            onDragStart()
                        }

                        let newValue = updateValue(at: gesture.location, in: size)
                        presentedValue = newValue
                        onDragChange(newValue)
                    }
                    .onEnded { _ in
                        guard isEnabled else { return }
                        isDragging = false
                        onDragEnd()
                    }
            )
            .onTapGesture(count: 2) {
                guard isEnabled else { return }
                presentedValue = 0
                onDragStart()
                onDragChange(0)
                onDragEnd()
            }
        }
        .frame(width: 34)
        .onAppear {
            presentedValue = clampedDB(valueDB)
        }
        .onChange(of: valueDB) { _, newValue in
            if !isDragging {
                presentedValue = clampedDB(newValue)
            }
        }
    }

    private var knob: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(isEnabled ? 0.74 : 0.32),
                            Color(red: 0.72, green: 0.72, blue: 0.76).opacity(isEnabled ? 1 : 0.42),
                            Color(red: 0.42, green: 0.42, blue: 0.46).opacity(isEnabled ? 1 : 0.42)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.white.opacity(isEnabled ? 0.4 : 0.12), lineWidth: 1)
                )

            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(accent.opacity(isEnabled ? (isDimmed ? 0.45 : 0.9) : 0.2))
                .frame(width: 24, height: 4)
        }
        .frame(width: 34, height: knobHeight)
        .shadow(color: .black.opacity(0.45), radius: 8, y: 6)
    }

    private func tickMarks(height: CGFloat) -> some View {
        VStack(spacing: 0) {
            ForEach(0..<13, id: \.self) { index in
                Spacer(minLength: 0)
                Rectangle()
                    .fill(.white.opacity(index.isMultiple(of: 2) ? 0.18 : 0.09))
                    .frame(width: index.isMultiple(of: 2) ? 11 : 7, height: 1)
                Spacer(minLength: 0)
            }
        }
        .frame(height: height - knobHeight)
        .offset(y: knobHeight / 2)
    }

    private func updateValue(at location: CGPoint, in size: CGSize) -> Double {
        let usableHeight = max(size.height - knobHeight, 1)
        let adjustedY = (location.y - knobHeight / 2).clamped(to: 0...usableHeight)
        let normalized = 1 - (adjustedY / usableHeight)
        return clampedDB(normalizedToDB(normalized, minDB: minDB, maxDB: maxDB))
    }

    private func clampedDB(_ value: Double) -> Double {
        value.clamped(to: minDB...maxDB)
    }
}

private struct MixerLevelMeter: View {
    let level: Double
    let accent: Color
    let isDimmed: Bool

    var body: some View {
        VStack(spacing: 2) {
            ForEach((0..<34).reversed(), id: \.self) { index in
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(segmentColor(for: index))
                    .frame(width: 14, height: 5)
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(isDimmed ? 0.18 : 0.32))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(.white.opacity(0.08), lineWidth: 1)
                )
        )
        .frame(width: 22, height: 260)
        .animation(.easeOut(duration: 0.12), value: level)
    }

    private func segmentColor(for index: Int) -> Color {
        let threshold = Double(index + 1) / 34
        guard level >= threshold else {
            return .white.opacity(isDimmed ? 0.04 : 0.08)
        }

        if threshold > 0.82 {
            return Color(red: 0.96, green: 0.45, blue: 0.35)
        } else if threshold > 0.58 {
            return Color(red: 0.98, green: 0.83, blue: 0.38)
        } else {
            return accent.opacity(isDimmed ? 0.42 : 0.88)
        }
    }
}

private struct MixerStripPalette {
    let accent: Color
    let glow: Color
    let edgeColor: Color
    let stripBackground: [Color]
    let displayBackground: [Color]
    let displayText: Color
    let secondaryText: Color
    let symbol: String

    static func make(for fader: FaderState) -> MixerStripPalette {
        guard fader.isActive else {
            return MixerStripPalette(
                accent: .white.opacity(0.3),
                glow: .white,
                edgeColor: .white,
                stripBackground: [
                    Color(red: 0.22, green: 0.22, blue: 0.24),
                    Color(red: 0.18, green: 0.18, blue: 0.20),
                    Color(red: 0.15, green: 0.15, blue: 0.17)
                ],
                displayBackground: [Color.white.opacity(0.08), Color.white.opacity(0.02)],
                displayText: .white.opacity(0.28),
                secondaryText: .white.opacity(0.18),
                symbol: "slider.horizontal.3"
            )
        }

        let accent = Color(hex: fader.roleColorHex) ?? defaultAccent(for: fader.role)
        switch category(for: fader.role) {
        case .dialogue:
            return MixerStripPalette(
                accent: accent,
                glow: accent,
                edgeColor: accent,
                stripBackground: [
                    Color(red: 0.34, green: 0.31, blue: 0.18),
                    Color(red: 0.22, green: 0.20, blue: 0.13),
                    Color(red: 0.14, green: 0.14, blue: 0.15)
                ],
                displayBackground: [Color(red: 0.35, green: 0.29, blue: 0.12), Color(red: 0.17, green: 0.15, blue: 0.10)],
                displayText: accent,
                secondaryText: accent.opacity(0.88),
                symbol: "speaker.wave.2.fill"
            )
        case .music:
            return MixerStripPalette(
                accent: accent,
                glow: accent,
                edgeColor: accent,
                stripBackground: [
                    Color(red: 0.10, green: 0.24, blue: 0.18),
                    Color(red: 0.11, green: 0.16, blue: 0.16),
                    Color(red: 0.12, green: 0.14, blue: 0.15)
                ],
                displayBackground: [Color(red: 0.11, green: 0.38, blue: 0.24), Color(red: 0.07, green: 0.18, blue: 0.15)],
                displayText: accent,
                secondaryText: accent.opacity(0.88),
                symbol: "music.note"
            )
        case .effects:
            return MixerStripPalette(
                accent: accent,
                glow: accent,
                edgeColor: accent,
                stripBackground: [
                    Color(red: 0.23, green: 0.16, blue: 0.28),
                    Color(red: 0.16, green: 0.14, blue: 0.20),
                    Color(red: 0.12, green: 0.12, blue: 0.15)
                ],
                displayBackground: [Color(red: 0.31, green: 0.18, blue: 0.39), Color(red: 0.16, green: 0.12, blue: 0.25)],
                displayText: accent,
                secondaryText: accent.opacity(0.88),
                symbol: "waveform"
            )
        case .generic:
            return MixerStripPalette(
                accent: accent,
                glow: accent,
                edgeColor: accent,
                stripBackground: [
                    Color(red: 0.18, green: 0.20, blue: 0.27),
                    Color(red: 0.14, green: 0.15, blue: 0.20),
                    Color(red: 0.12, green: 0.12, blue: 0.16)
                ],
                displayBackground: [accent.opacity(0.34), accent.opacity(0.16)],
                displayText: accent,
                secondaryText: accent.opacity(0.88),
                symbol: "slider.horizontal.3"
            )
        }
    }

    private enum RoleCategory {
        case dialogue
        case music
        case effects
        case generic
    }

    private static func category(for role: String?) -> RoleCategory {
        let lowercased = role?.lowercased() ?? ""
        if lowercased.contains("dialogue") { return .dialogue }
        if lowercased.contains("music") { return .music }
        if lowercased.contains("effect") { return .effects }
        return .generic
    }

    private static func defaultAccent(for role: String?) -> Color {
        switch category(for: role) {
        case .dialogue:
            return Color(red: 0.94, green: 0.78, blue: 0.38)
        case .music:
            return Color(red: 0.34, green: 0.86, blue: 0.56)
        case .effects:
            return Color(red: 0.77, green: 0.46, blue: 0.96)
        case .generic:
            return Color(red: 0.42, green: 0.76, blue: 0.98)
        }
    }
}

private func dbToNormalized(_ db: Double, minDB: Double, maxDB: Double) -> Double {
    if db <= minDB { return 0 }
    if db >= maxDB { return 1 }

    let positiveHeadroom = max(0.0, maxDB)
    if positiveHeadroom > 0, db >= 0 {
        return 0.75 + (db / positiveHeadroom) * 0.25
    }

    let upperBound = positiveHeadroom > 0 ? 0.0 : maxDB
    let span = upperBound - minDB
    guard span > 0 else { return 0 }

    let normalized = (db - minDB) / span
    let sliderTop = positiveHeadroom > 0 ? 0.75 : 1.0
    return sqrt(max(0, normalized)) * sliderTop
}

private func normalizedToDB(_ normalized: Double, minDB: Double, maxDB: Double) -> Double {
    if normalized <= 0 { return minDB }
    if normalized >= 1 { return maxDB }

    let positiveHeadroom = max(0.0, maxDB)
    if positiveHeadroom > 0, normalized >= 0.75 {
        return ((normalized - 0.75) / 0.25) * positiveHeadroom
    }

    let sliderTop = positiveHeadroom > 0 ? 0.75 : 1.0
    let upperBound = positiveHeadroom > 0 ? 0.0 : maxDB
    let span = upperBound - minDB
    guard span > 0 else { return minDB }

    let curve = normalized / sliderTop
    return (curve * curve) * span + minDB
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let divisor = pow(10.0, Double(places))
        return (self * divisor).rounded() / divisor
    }

    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

private extension Color {
    init?(hex: String?) {
        guard var raw = hex?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }

        raw = raw.replacingOccurrences(of: "#", with: "")
        guard raw.count == 6, let value = Int(raw, radix: 16) else {
            return nil
        }

        let red = Double((value >> 16) & 0xFF) / 255.0
        let green = Double((value >> 8) & 0xFF) / 255.0
        let blue = Double(value & 0xFF) / 255.0
        self = Color(red: red, green: green, blue: blue)
    }
}
