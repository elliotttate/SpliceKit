import SwiftUI

struct StatusPanel: View {
    @ObservedObject var model: PatcherModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: headerIcon)
                    .font(.title)
                    .foregroundStyle(headerColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(headerTitle)
                        .font(.title.bold())
                    Text(headerSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            // Status details
            VStack(alignment: .leading, spacing: 10) {
                if !model.fcpVersion.isEmpty {
                    Label {
                        if model.status == .fcpUpdateAvailable {
                            Text("Modded copy v\(model.fcpVersion) \u{2192} Stock v\(model.stockFcpVersion)")
                        } else {
                            Text("\((model.sourceApp as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")) v\(model.fcpVersion)")
                        }
                    } icon: {
                        Image(systemName: "film.stack")
                    }
                    .font(.subheadline)
                }

                Label {
                    HStack(spacing: 6) {
                        Text(model.bridgeConnected ? "Connected" : "Not Running")
                        Circle()
                            .fill(model.bridgeConnected ? .green : .orange)
                            .frame(width: 8, height: 8)
                    }
                } icon: {
                    Image(systemName: "network")
                }
                .font(.subheadline)
            }

            // Error display
            if let err = model.errorMessage {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.red.opacity(0.1))
                    .cornerRadius(6)
            }

            Spacer()

            // Action buttons
            HStack(spacing: 12) {
                Button(role: .destructive) {
                    model.uninstall()
                } label: {
                    Label("Uninstall", systemImage: "trash")
                }

                Spacer()

                Button {
                    model.checkStatus()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }

                if model.status == .updateAvailable {
                    Button {
                        model.launch()
                    } label: {
                        Label("Launch FCP", systemImage: "play.fill")
                    }

                    Button {
                        model.updateSpliceKit()
                    } label: {
                        Label("Update SpliceKit", systemImage: "arrow.up.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                } else if model.status == .fcpUpdateAvailable {
                    Button {
                        model.launch()
                    } label: {
                        Label("Launch FCP", systemImage: "play.fill")
                    }

                    Button {
                        model.rebuildModdedApp()
                    } label: {
                        Label("Rebuild", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                } else {
                    Button {
                        model.launch()
                    } label: {
                        Label("Launch FCP", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
        }
        .padding(24)
        .task {
            // Keep the connection indicator in sync with FCP's live state.
            // Runs only while the panel is mounted; cancelled automatically
            // on panel/view dismissal.
            while !Task.isCancelled {
                await model.pollBridgeStatus()
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }

    private var headerIcon: String {
        switch model.status {
        case .updateAvailable: return "arrow.up.circle.fill"
        case .fcpUpdateAvailable: return "exclamationmark.triangle.fill"
        default: return "checkmark.seal.fill"
        }
    }

    private var headerColor: Color {
        switch model.status {
        case .updateAvailable: return .blue
        case .fcpUpdateAvailable: return .orange
        default: return .green
        }
    }

    private var headerTitle: String {
        switch model.status {
        case .updateAvailable: return "SpliceKit Update Available"
        case .fcpUpdateAvailable: return "Final Cut Pro Updated"
        default: return "SpliceKit Installed"
        }
    }

    private var headerSubtitle: String {
        switch model.status {
        case .updateAvailable:
            return "A newer version of SpliceKit is ready to install."
        case .fcpUpdateAvailable:
            return "Final Cut Pro has been updated. Rebuild the modded copy to use the latest version."
        default:
            return "Final Cut Pro is ready to launch with enhanced features."
        }
    }
}
