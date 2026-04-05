import SwiftUI
import Sparkle

// MARK: - Sparkle Auto-Update

@MainActor
final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates, options: [.initial, .new])
            .receive(on: DispatchQueue.main)
            .assign(to: &$canCheckForUpdates)
    }
}

struct CheckForUpdatesView: View {
    @ObservedObject var viewModel: CheckForUpdatesViewModel
    let updater: SPUUpdater

    var body: some View {
        Button("Check for Updates\u{2026}", action: updater.checkForUpdates)
            .disabled(!viewModel.canCheckForUpdates)
    }
}

// MARK: - App Entry Point

@main
struct SpliceKitApp: App {
    private let updaterController: SPUStandardUpdaterController
    @StateObject private var checkForUpdatesVM: CheckForUpdatesViewModel
    @StateObject private var model = PatcherModel()

    init() {
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.updaterController = controller
        self._checkForUpdatesVM = StateObject(wrappedValue:
            CheckForUpdatesViewModel(updater: controller.updater)
        )
    }

    var body: some Scene {
        WindowGroup {
            WizardView(model: model)
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(
                    viewModel: checkForUpdatesVM,
                    updater: updaterController.updater
                )
            }
        }

        Window("Logs", id: "log-panel") {
            LogPanelView(model: model)
        }
        .defaultSize(width: 600, height: 400)
    }
}
