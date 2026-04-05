import SwiftUI

struct WelcomePanel: View {
    @ObservedObject var model: PatcherModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Welcome to SpliceKit")
                .font(.title.bold())

            Text("To get started, please select the version of Final Cut Pro you would like to enhance.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
                .frame(height: 8)

            // FCP edition picker
            if model.hasBothEditions {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Final Cut Pro Edition")
                        .font(.subheadline.bold())
                    Picker("", selection: Binding(
                        get: { model.sourceApp },
                        set: { model.switchEdition(to: $0) }
                    )) {
                        ForEach(model.availableEditions, id: \.path) { edition in
                            Text(edition.label).tag(edition.path)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
            }

            // FCP version info
            if !model.fcpVersion.isEmpty {
                Label {
                    Text("\((model.sourceApp as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")) v\(model.fcpVersion)")
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                .font(.subheadline)
            } else if model.availableEditions.isEmpty {
                Label {
                    Text("Final Cut Pro is not installed")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .font(.subheadline)
            }

            // Error display
            if let err = model.errorMessage {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(8)
                    .background(.red.opacity(0.1))
                    .cornerRadius(6)
            }

            Spacer()

            // Action bar
            HStack {
                Spacer()
                Button {
                    model.patch()
                } label: {
                    Text("Continue")
                        .frame(minWidth: 80)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.availableEditions.isEmpty)
            }
        }
        .padding(24)
    }
}
