import SwiftUI

@main
struct MixerApp: App {
    @StateObject private var model = MixerModel()

    var body: some Scene {
        WindowGroup("SpliceKit Mixer") {
            MixerView(model: model)
                .onAppear {
                    model.start()
                }
                .onDisappear {
                    model.stop()
                }
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1036, height: 742)
    }
}
