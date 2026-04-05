import SwiftUI

struct StatusPanel: View {
    @ObservedObject var model: PatcherModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.title)
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("SpliceKit Installed")
                        .font(.title.bold())
                    Text("Final Cut Pro is ready to launch with enhanced features.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            // Status details
            VStack(alignment: .leading, spacing: 10) {
                if !model.fcpVersion.isEmpty {
                    Label {
                        Text("\((model.sourceApp as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")) v\(model.fcpVersion)")
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

                Button {
                    model.launch()
                } label: {
                    Label("Launch FCP", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(24)
    }
}
