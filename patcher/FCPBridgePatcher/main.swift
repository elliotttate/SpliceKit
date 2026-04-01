import SwiftUI
import AppKit
import Sparkle

// MARK: - Patcher Logic

enum PatchStatus: Equatable {
    case notPatched
    case patched
    case running
    case unknown
}

enum PatchStep: String, CaseIterable {
    case checkPrereqs = "Checking prerequisites"
    case copyApp = "Copying Final Cut Pro"
    case buildDylib = "Building FCPBridge dylib"
    case installFramework = "Installing framework"
    case injectDylib = "Injecting into binary"
    case signApp = "Re-signing application"
    case configureDefaults = "Configuring defaults"
    case setupMCP = "Setting up MCP server"
    case done = "Done"
}

@MainActor
class PatcherModel: ObservableObject {
    @Published var status: PatchStatus = .unknown
    @Published var currentStep: PatchStep?
    @Published var completedSteps: Set<PatchStep> = []
    @Published var log: String = ""
    @Published var isPatching = false
    @Published var isPatchComplete = false
    @Published var errorMessage: String?
    @Published var fcpVersion: String = ""
    @Published var bridgeConnected = false

    let sourceApp = "/Applications/Final Cut Pro.app"
    let destDir: String
    let moddedApp: String
    let repoDir: String

    init() {
        destDir = NSHomeDirectory() + "/Desktop/FinalCutPro_Modded"
        moddedApp = destDir + "/Final Cut Pro.app"
        // Find FCPBridge sources. Priority:
        // 1. Embedded in app bundle (Resources/Sources/) — self-contained release
        // 2. Relative to app bundle (developer running from repo checkout)
        // 3. Common local paths
        // 4. Cache dir (will download into it during patch)
        var found = ""

        // 1. Embedded in app bundle
        if let resourcePath = Bundle.main.resourcePath {
            let embedded = resourcePath + "/Sources"
            if FileManager.default.fileExists(atPath: embedded + "/FCPBridge.m") {
                found = resourcePath
            }
        }

        // 2. Relative to app bundle (developer workflow)
        if found.isEmpty {
            var dir = (Bundle.main.bundlePath as NSString).deletingLastPathComponent
            for _ in 0..<5 {
                if FileManager.default.fileExists(atPath: dir + "/Sources/FCPBridge.m") {
                    found = dir; break
                }
                dir = (dir as NSString).deletingLastPathComponent
            }
        }

        // 3. Common locations
        if found.isEmpty {
            for path in [
                NSHomeDirectory() + "/Documents/GitHub/FCPBridge",
                NSHomeDirectory() + "/Desktop/FCPBridge",
                NSHomeDirectory() + "/FCPBridge",
            ] {
                if FileManager.default.fileExists(atPath: path + "/Sources/FCPBridge.m") {
                    found = path; break
                }
            }
        }

        // 4. Cache dir (download during patch)
        if found.isEmpty {
            found = NSHomeDirectory() + "/Library/Caches/FCPBridge"
        }
        repoDir = found
        checkStatus()
    }

    func checkStatus() {
        let binary = moddedApp + "/Contents/MacOS/Final Cut Pro"
        if FileManager.default.fileExists(atPath: binary) {
            // Check if FCPBridge is injected
            let result = shell("otool -L '\(binary)' 2>/dev/null | grep FCPBridge")
            if result.contains("FCPBridge") {
                status = .patched

                // Check if running
                let ps = shell("lsof -i :9876 2>/dev/null | grep LISTEN")
                bridgeConnected = !ps.isEmpty

                // Get FCP version
                let ver = shell("/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' '\(moddedApp)/Contents/Info.plist' 2>/dev/null")
                fcpVersion = ver.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                status = .notPatched
            }
        } else {
            status = .notPatched
        }

        // Get source FCP version
        if fcpVersion.isEmpty {
            let ver = shell("/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' '\(sourceApp)/Contents/Info.plist' 2>/dev/null")
            fcpVersion = ver.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func patch() {
        guard !isPatching else { return }
        isPatching = true
        isPatchComplete = false
        errorMessage = nil
        log = ""
        completedSteps = []

        Task.detached { [self] in
            do {
                try await self.runPatch()
                await MainActor.run {
                    self.isPatchComplete = true
                    self.status = .patched
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.appendLog("ERROR: \(error.localizedDescription)")
                }
            }
            await MainActor.run {
                self.isPatching = false
            }
        }
    }

    func launch() {
        let binary = moddedApp + "/Contents/MacOS/Final Cut Pro"
        appendLog("Launching modded FCP...")
        Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: binary)
            try? p.run()
        }

        // Wait and check connection
        Task {
            try? await Task.sleep(for: .seconds(12))
            await MainActor.run {
                checkStatus()
                if bridgeConnected {
                    appendLog("FCPBridge connected on port 9876")
                } else {
                    appendLog("Waiting for FCPBridge... (check ~/Desktop/fcpbridge.log)")
                }
            }
        }
    }

    func uninstall() {
        appendLog("Removing modded FCP...")
        shell("pkill -f FinalCutPro_Modded 2>/dev/null; sleep 1")
        do {
            try FileManager.default.removeItem(atPath: destDir)
            appendLog("Removed \(destDir)")
            status = .notPatched
            bridgeConnected = false
        } catch {
            appendLog("Error: \(error.localizedDescription)")
        }
    }

    // MARK: - Patch Steps

    private nonisolated func runPatch() async throws {
        // Step 1: Prerequisites
        await setStepAsync(.checkPrereqs)
        if shell("xcode-select -p 2>/dev/null").isEmpty {
            await logAsync("Xcode Command Line Tools not found. Installing...")
            shell("xcode-select --install 2>/dev/null")
            throw PatchError.msg("Xcode Command Line Tools are required.\n\nAn installer window should have appeared. Please complete the installation, then click \"Patch Final Cut Pro\" again.")
        }
        await logAsync("Xcode tools: OK")

        let sourceApp = await MainActor.run { self.sourceApp }
        let fcpVersion = await MainActor.run { self.fcpVersion }
        let repoDir = await MainActor.run { self.repoDir }
        let destDir = await MainActor.run { self.destDir }
        let moddedApp = await MainActor.run { self.moddedApp }

        guard FileManager.default.fileExists(atPath: sourceApp) else {
            throw PatchError.msg("Final Cut Pro not found at \(sourceApp)")
        }
        await logAsync("FCP \(fcpVersion): OK")

        let repoSources = repoDir + "/Sources/FCPBridge.m"
        if !FileManager.default.fileExists(atPath: repoSources) {
            await logAsync("Downloading FCPBridge sources...")
            let dlResult = shell("""
                mkdir -p '\(repoDir)' && \
                curl -sL https://github.com/elliotttate/FCPBridge/archive/refs/heads/main.zip \
                    -o /tmp/fcpbridge_src.zip && \
                unzip -qo /tmp/fcpbridge_src.zip -d /tmp/fcpbridge_extract && \
                cp -R /tmp/fcpbridge_extract/FCPBridge-main/* '\(repoDir)/' && \
                rm -rf /tmp/fcpbridge_src.zip /tmp/fcpbridge_extract 2>&1
                """)
            guard FileManager.default.fileExists(atPath: repoSources) else {
                throw PatchError.msg("Failed to download FCPBridge sources. Make sure you have an internet connection.\n\(dlResult)")
            }
            await logAsync("Downloaded FCPBridge sources")
        } else {
            await logAsync("FCPBridge sources: OK")
        }
        await completeStepAsync(.checkPrereqs)

        // Step 2: Copy app
        await setStepAsync(.copyApp)
        if !FileManager.default.fileExists(atPath: moddedApp) {
            await logAsync("Copying FCP (~6GB, please wait)...")
            let r = shell("mkdir -p '\(destDir)' && cp -R '\(sourceApp)' '\(moddedApp)' 2>&1")
            if !FileManager.default.fileExists(atPath: moddedApp) {
                throw PatchError.msg("Copy failed: \(r)")
            }
            shell("mkdir -p '\(moddedApp)/Contents/_MASReceipt' && cp '\(sourceApp)/Contents/_MASReceipt/receipt' '\(moddedApp)/Contents/_MASReceipt/' 2>/dev/null")
            shell("xattr -cr '\(moddedApp)' 2>/dev/null")
            await logAsync("Copied to \(destDir)")
        } else {
            await logAsync("Using existing copy")
        }
        await completeStepAsync(.copyApp)

        // Step 3: Build dylib
        await setStepAsync(.buildDylib)
        await logAsync("Compiling FCPBridge dylib...")
        let buildDir = NSTemporaryDirectory() + "FCPBridge_build"
        shell("mkdir -p '\(buildDir)'")
        let sources = ["FCPBridge.m", "FCPBridgeRuntime.m", "FCPBridgeSwizzle.m", "FCPBridgeServer.m", "FCPTranscriptPanel.m", "FCPCommandPalette.m"]
            .map { "'\(repoDir)/Sources/\($0)'" }.joined(separator: " ")
        let buildResult = shell("""
            clang -arch arm64 -arch x86_64 -mmacosx-version-min=14.0 \
            -framework Foundation -framework AppKit -framework AVFoundation \
            -fobjc-arc -fmodules -Wno-deprecated-declarations \
            -undefined dynamic_lookup -dynamiclib \
            -install_name @rpath/FCPBridge.framework/Versions/A/FCPBridge \
            -I '\(repoDir)/Sources' \
            \(sources) -o '\(buildDir)/FCPBridge' 2>&1
            """)
        guard FileManager.default.fileExists(atPath: buildDir + "/FCPBridge") else {
            throw PatchError.msg("Build failed:\n\(buildResult)")
        }
        await logAsync("Built universal dylib (arm64 + x86_64)")

        // Build silence-detector tool
        let silenceSwift = repoDir + "/tools/silence-detector.swift"
        let silenceBin = buildDir + "/silence-detector"
        if FileManager.default.fileExists(atPath: silenceSwift) {
            let swiftResult = shell("swiftc -O -suppress-warnings -o '\(silenceBin)' '\(silenceSwift)' 2>&1")
            if FileManager.default.fileExists(atPath: silenceBin) {
                await logAsync("Built silence-detector tool")
            } else {
                await logAsync("Warning: silence-detector build failed (silence removal will be unavailable)")
            }
        } else {
            // Try to use pre-built binary from Resources
            let prebuilt = repoDir + "/tools/silence-detector"
            if FileManager.default.fileExists(atPath: prebuilt) {
                shell("cp '\(prebuilt)' '\(silenceBin)'")
                await logAsync("Using pre-built silence-detector")
            }
        }

        await completeStepAsync(.buildDylib)

        // Step 4: Install framework
        await setStepAsync(.installFramework)
        let fwDir = moddedApp + "/Contents/Frameworks/FCPBridge.framework"
        shell("""
            mkdir -p '\(fwDir)/Versions/A/Resources'
            cp '\(buildDir)/FCPBridge' '\(fwDir)/Versions/A/FCPBridge'
            cd '\(fwDir)/Versions' && ln -sf A Current
            cd '\(fwDir)' && ln -sf Versions/Current/FCPBridge FCPBridge
            cd '\(fwDir)' && ln -sf Versions/Current/Resources Resources
            """)
        let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
            <key>CFBundleIdentifier</key><string>com.fcpbridge.FCPBridge</string>
            <key>CFBundleName</key><string>FCPBridge</string>
            <key>CFBundleVersion</key><string>2.1.0</string>
            <key>CFBundlePackageType</key><string>FMWK</string>
            <key>CFBundleExecutable</key><string>FCPBridge</string>
            </dict></plist>
            """
        try plist.write(toFile: fwDir + "/Versions/A/Resources/Info.plist", atomically: true, encoding: .utf8)

        // Deploy silence-detector to a location the command palette can find
        if FileManager.default.fileExists(atPath: silenceBin) {
            let toolsDir = NSHomeDirectory() + "/Desktop/FCPBridge/build"
            shell("mkdir -p '\(toolsDir)' && cp '\(silenceBin)' '\(toolsDir)/silence-detector'")
            // Also try Documents/GitHub path
            let toolsDir2 = NSHomeDirectory() + "/Documents/GitHub/FCPBridge/build"
            shell("mkdir -p '\(toolsDir2)' && cp '\(silenceBin)' '\(toolsDir2)/silence-detector' 2>/dev/null")
        }

        await logAsync("Framework installed")
        await completeStepAsync(.installFramework)

        // Step 5: Inject LC_LOAD_DYLIB
        await setStepAsync(.injectDylib)
        let binary = moddedApp + "/Contents/MacOS/Final Cut Pro"
        let alreadyInjected = shell("otool -L '\(binary)' 2>/dev/null | grep FCPBridge")
        if alreadyInjected.isEmpty {
            let insertDylib = "/tmp/fcpbridge_insert_dylib"
            if !FileManager.default.fileExists(atPath: insertDylib) {
                await logAsync("Building insert_dylib tool...")
                shell("""
                    cd /tmp && rm -rf _insert_dylib_build && mkdir _insert_dylib_build && cd _insert_dylib_build && \
                    curl -sL https://github.com/tyilo/insert_dylib/archive/refs/heads/master.zip -o insert_dylib.zip && \
                    unzip -qo insert_dylib.zip && \
                    clang -o '\(insertDylib)' insert_dylib-master/insert_dylib/main.c -framework Foundation 2>/dev/null && \
                    cd /tmp && rm -rf _insert_dylib_build
                    """)
            }
            shell("'\(insertDylib)' --inplace --all-yes '@rpath/FCPBridge.framework/Versions/A/FCPBridge' '\(binary)' 2>&1")
            await logAsync("Injected LC_LOAD_DYLIB")
        } else {
            await logAsync("Already injected (skipping)")
        }
        await completeStepAsync(.injectDylib)

        // Step 6: Re-sign
        await setStepAsync(.signApp)
        await logAsync("Signing frameworks and plugins...")
        let entitlements = buildDir + "/entitlements.plist"
        let entPlist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
            <key>com.apple.security.cs-disable-library-validation</key><true/>
            <key>com.apple.security.cs-allow-dyld-environment-variables</key><true/>
            <key>com.apple.security.get-task-allow</key><true/>
            </dict></plist>
            """
        try entPlist.write(toFile: entitlements, atomically: true, encoding: .utf8)

        shell("/usr/libexec/PlistBuddy -c \"Add :NSSpeechRecognitionUsageDescription string 'FCPBridge uses speech recognition to transcribe timeline audio for text-based editing.'\" '\(moddedApp)/Contents/Info.plist' 2>/dev/null")

        shell("""
            for fw in '\(moddedApp)'/Contents/Frameworks/*.framework; do codesign --force --sign - "$fw" 2>/dev/null; done
            find '\(moddedApp)/Contents/PlugIns' \\( -name '*.bundle' -o -name '*.appex' -o -name '*.pluginkit' -o -name '*.fxp' \\) -type d | while read p; do codesign --force --sign - "$p" 2>/dev/null; done
            codesign --force --sign - '\(moddedApp)/Contents/Helpers/RegisterProExtension.app' 2>/dev/null
            find '\(moddedApp)' -name '*.fxp' -type d | while read fxp; do codesign --force --sign - "$fxp" 2>/dev/null; done
            codesign --force --sign - '\(moddedApp)/Contents/PlugIns/InternalFiltersXPC.pluginkit' 2>/dev/null
            codesign --force --sign - '\(moddedApp)/Contents/Frameworks/Flexo.framework' 2>/dev/null
            codesign --force --sign - '\(moddedApp)/Contents/Frameworks/FCPBridge.framework' 2>/dev/null
            codesign --force --sign - --entitlements '\(entitlements)' '\(moddedApp)' 2>/dev/null
            """)

        let verify = shell("codesign --verify --verbose '\(moddedApp)' 2>&1")
        if verify.contains("valid") || verify.contains("satisfies") {
            await logAsync("Signature verified")
        } else {
            throw PatchError.msg("Signing failed: \(verify)")
        }
        await completeStepAsync(.signApp)

        // Step 7: Defaults
        await setStepAsync(.configureDefaults)
        shell("defaults write com.apple.FinalCut CloudContentFirstLaunchCompleted -bool true 2>/dev/null")
        shell("defaults write com.apple.FinalCut FFCloudContentDisabled -bool true 2>/dev/null")
        await logAsync("CloudContent defaults configured")
        await completeStepAsync(.configureDefaults)

        // Step 8: MCP
        await setStepAsync(.setupMCP)
        let mcpServer = repoDir + "/mcp/server.py"
        if FileManager.default.fileExists(atPath: mcpServer) {
            await logAsync("MCP server: \(mcpServer)")
        }
        await completeStepAsync(.setupMCP)

        await setStepAsync(.done)
        await logAsync("\nPatching complete! You can now launch the modded FCP.")
    }

    // MARK: - Helpers

    @discardableResult
    nonisolated func shell(_ command: String) -> String {
        let process = Process()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        try? process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func appendLog(_ text: String) {
        log += text + "\n"
    }

    private nonisolated func logAsync(_ text: String) async {
        await MainActor.run { self.log += text + "\n" }
    }

    private nonisolated func setStepAsync(_ step: PatchStep) async {
        await MainActor.run { self.currentStep = step }
    }

    private nonisolated func completeStepAsync(_ step: PatchStep) async {
        await MainActor.run { self.completedSteps.insert(step) }
    }

    private func setStep(_ step: PatchStep) async {
        currentStep = step
    }

    private func completeStep(_ step: PatchStep) async {
        completedSteps.insert(step)
    }
}

enum PatchError: LocalizedError {
    case msg(String)
    var errorDescription: String? {
        switch self { case .msg(let s): return s }
    }
}

// MARK: - SwiftUI Views

struct ContentView: View {
    @StateObject private var model = PatcherModel()
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView

            Divider()

            // Main content
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    statusCard
                    if model.isPatching {
                        progressView
                    }
                    if !model.log.isEmpty {
                        logView
                    }
                }
                .padding(20)
            }

            Divider()

            // Action buttons
            actionBar
        }
        .frame(width: 580, height: 620)
        .clipped()
    }

    // MARK: - Header

    var headerView: some View {
        HStack(spacing: 12) {
            Image(systemName: "film.stack")
                .font(.system(size: 32))
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("FCPBridge Patcher")
                    .font(.title2.bold())
                Text("Direct programmatic control of Final Cut Pro")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                updaterController.updater.checkForUpdates()
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Check for Updates")
            Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")")
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.blue.opacity(0.1))
                .cornerRadius(4)
        }
        .padding(16)
        .background(.bar)
    }

    // MARK: - Status Card

    var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                statusIcon
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle).font(.headline)
                    Text(statusSubtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.status == .patched {
                    Circle()
                        .fill(model.bridgeConnected ? .green : .orange)
                        .frame(width: 10, height: 10)
                    Text(model.bridgeConnected ? "Connected" : "Not Running")
                        .font(.caption)
                        .foregroundStyle(model.bridgeConnected ? .green : .orange)
                }
            }

            if !model.fcpVersion.isEmpty {
                Label("Final Cut Pro v\(model.fcpVersion)", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let err = model.errorMessage {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(8)
                    .background(.red.opacity(0.1))
                    .cornerRadius(6)
            }
        }
        .padding(16)
        .background(.background)
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator))
    }

    var statusIcon: some View {
        Group {
            switch model.status {
            case .patched:
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .font(.title)
            case .notPatched:
                Image(systemName: "wrench.and.screwdriver")
                    .foregroundStyle(.orange)
                    .font(.title)
            case .running:
                Image(systemName: "play.circle.fill")
                    .foregroundStyle(.blue)
                    .font(.title)
            case .unknown:
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(.secondary)
                    .font(.title)
            }
        }
    }

    var statusTitle: String {
        switch model.status {
        case .patched: return "FCPBridge Installed"
        case .notPatched: return "Not Patched"
        case .running: return "FCP Running with Bridge"
        case .unknown: return "Checking..."
        }
    }

    var statusSubtitle: String {
        switch model.status {
        case .patched: return model.moddedApp
        case .notPatched: return "Ready to patch Final Cut Pro"
        case .running: return "JSON-RPC on 127.0.0.1:9876"
        case .unknown: return ""
        }
    }

    // MARK: - Progress

    var progressView: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(PatchStep.allCases, id: \.self) { step in
                if step == .done { EmptyView() }
                else {
                    HStack(spacing: 8) {
                        if model.completedSteps.contains(step) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else if model.currentStep == step {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "circle")
                                .foregroundStyle(.secondary)
                        }
                        Text(step.rawValue)
                            .font(.callout)
                            .foregroundStyle(model.currentStep == step ? .primary : .secondary)
                    }
                }
            }
        }
        .padding(16)
        .background(.background)
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator))
    }

    // MARK: - Log

    var logView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Log")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            ScrollView {
                Text(model.log)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 150)
        }
        .padding(12)
        .background(Color(nsColor: .textBackgroundColor))
        .cornerRadius(8)
    }

    // MARK: - Action Bar

    var actionBar: some View {
        HStack(spacing: 12) {
            if model.status == .patched {
                Button(role: .destructive) {
                    model.uninstall()
                } label: {
                    Label("Uninstall", systemImage: "trash")
                }
                .disabled(model.isPatching)

                Spacer()

                Button {
                    model.checkStatus()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(model.isPatching)

                Button {
                    model.launch()
                } label: {
                    Label("Launch FCP", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isPatching)

            } else {
                Spacer()

                Button {
                    model.patch()
                } label: {
                    Label(model.isPatching ? "Patching..." : "Patch Final Cut Pro",
                          systemImage: "hammer.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.isPatching)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }
}

// MARK: - Sparkle Auto-Update

final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

struct CheckForUpdatesView: View {
    @ObservedObject var viewModel: CheckForUpdatesViewModel
    let updater: SPUUpdater

    var body: some View {
        Button("Check for Updates…", action: updater.checkForUpdates)
            .disabled(!viewModel.canCheckForUpdates)
    }
}

// MARK: - App Entry Point

@main
struct FCPBridgePatcherApp: App {
    private let updaterController: SPUStandardUpdaterController
    @StateObject private var checkForUpdatesVM: CheckForUpdatesViewModel

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
            ContentView()
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
    }
}
