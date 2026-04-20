import SwiftUI
import Sparkle
import AppKit

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
    private static let helpURL = URL(string: "https://splicekit.fcp.cafe/installation/")!
    private static let sentryCrashTestMessage = "Sentry test crash triggered from patcher menu bar"
    private let updaterController: SPUStandardUpdaterController
    @StateObject private var checkForUpdatesVM: CheckForUpdatesViewModel
    @StateObject private var model = PatcherModel()

    init() {
        PatcherSentry.start()
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

    private static func triggerSentryCrashTest() {
        PatcherSentry.addBreadcrumb(
            "Manual crash test triggered from menu bar",
            category: "patcher.debug",
            level: .error
        )
        fatalError(sentryCrashTestMessage)
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

            CommandGroup(replacing: .help) {
                Button("SpliceKit Help") {
                    NSWorkspace.shared.open(Self.helpURL)
                }
            }

            CommandMenu("Debug") {
                Button("Crash Patcher for Sentry Test") {
                    Self.triggerSentryCrashTest()
                }
            }
        }

        Window("Logs", id: "log-panel") {
            LogPanelView(model: model)
        }
        .defaultSize(width: 600, height: 400)
    }
}
