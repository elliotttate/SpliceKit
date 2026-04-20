import SwiftUI

struct WizardView: View {
    @ObservedObject var model: PatcherModel

    var body: some View {
        HStack(spacing: 0) {
            iconColumn
            Divider()
            rightColumn
        }
        .frame(width: 900, height: 470)
        .preferredColorScheme(.dark)
    }

    // MARK: - Left Column

    private var iconColumn: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 128, height: 128)
            Text("SpliceKit")
                .font(.headline)
            Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(width: 200)
        .frame(maxHeight: .infinity)
        .background(.ultraThinMaterial)
    }

    // MARK: - Right Column

    private var rightColumn: some View {
        Group {
            switch model.currentPanel {
            case .welcome:
                WelcomePanel(model: model)
            case .patching:
                PatchingPanel(model: model)
            case .complete:
                StatusPanel(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
