import SwiftUI

struct LogPanelView: View {
    @ObservedObject var model: PatcherModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Logs")
                    .font(.headline)
                Spacer()
                Button("Clear") {
                    model.log = ""
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .disabled(model.log.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            // Log content
            ScrollView {
                ScrollViewReader { proxy in
                    VStack(alignment: .leading, spacing: 0) {
                        if model.log.isEmpty {
                            Text("No log output yet.")
                                .foregroundStyle(.tertiary)
                                .padding(12)
                        } else {
                            Text(model.log)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .padding(12)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id("bottom")
                    }
                    .onChange(of: model.log) { _, _ in
                        withAnimation {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .frame(minWidth: 500, minHeight: 300)
    }
}
