import SwiftUI

struct PatchingPanel: View {
    @ObservedObject var model: PatcherModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Setting Up")
                .font(.title.bold())

            Text("SpliceKit is enhancing Final Cut Pro. This may take several minutes.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
                .frame(height: 4)

            // Step progress
            VStack(alignment: .leading, spacing: 8) {
                ForEach(PatchStep.allCases, id: \.self) { step in
                    if step != .done {
                        HStack(spacing: 10) {
                            stepIcon(for: step)
                                .frame(width: 20, height: 20)
                            Text(step.rawValue)
                                .font(.callout)
                                .foregroundStyle(model.currentStep == step ? .primary : .secondary)
                        }
                    }
                }
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

            // Action bar
            HStack {
                if model.errorMessage != nil {
                    Button("Back") {
                        model.currentPanel = .welcome
                        model.errorMessage = nil
                    }
                }
                Spacer()
                if model.errorMessage != nil {
                    Button("Retry") {
                        model.patch()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(24)
        .onChange(of: model.isPatchComplete) { _, complete in
            if complete {
                model.currentPanel = .complete
            }
        }
    }

    @ViewBuilder
    private func stepIcon(for step: PatchStep) -> some View {
        if model.completedSteps.contains(step) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else if model.currentStep == step {
            ProgressView()
                .controlSize(.small)
        } else {
            Image(systemName: "circle")
                .foregroundStyle(.quaternary)
        }
    }
}
