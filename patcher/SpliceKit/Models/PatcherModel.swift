import SwiftUI
import AppKit

// MARK: - Types

enum PatchStatus: Equatable {
    case notPatched
    case patched
    case running
    case unknown
}

enum PatchStep: String, CaseIterable {
    case checkPrereqs = "Checking prerequisites"
    case copyApp = "Copying Final Cut Pro"
    case buildDylib = "Building SpliceKit dylib"
    case installFramework = "Installing framework"
    case injectDylib = "Injecting into binary"
    case signApp = "Re-signing application"
    case configureDefaults = "Configuring defaults"
    case setupMCP = "Setting up MCP server"
    case done = "Done"
}

enum WizardPanel: Int {
    case welcome
    case patching
    case complete
}

enum PatchError: LocalizedError {
    case msg(String)
    var errorDescription: String? {
        switch self { case .msg(let s): return s }
    }
}

// MARK: - Model

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
    @Published var currentPanel: WizardPanel = .welcome

    static let standardApp = "/Applications/Final Cut Pro.app"
    static let creatorStudioApp = "/Applications/Final Cut Pro Creator Studio.app"

    @Published var sourceApp: String
    let destDir: String
    var moddedApp: String { destDir + "/" + (sourceApp as NSString).lastPathComponent }
    let repoDir: String

    /// Which FCP editions are installed
    var availableEditions: [(label: String, path: String)] {
        var editions: [(String, String)] = []
        if FileManager.default.fileExists(atPath: Self.standardApp) {
            editions.append(("Final Cut Pro", Self.standardApp))
        }
        if FileManager.default.fileExists(atPath: Self.creatorStudioApp) {
            editions.append(("Final Cut Pro Creator Studio", Self.creatorStudioApp))
        }
        return editions
    }

    var hasBothEditions: Bool { availableEditions.count > 1 }

    func switchEdition(to path: String) {
        sourceApp = path
        fcpVersion = ""
        checkStatus()
    }

    init() {
        // Auto-detect FCP edition: prefer standard, fall back to Creator Studio
        let fm = FileManager.default
        if fm.fileExists(atPath: Self.standardApp) {
            sourceApp = Self.standardApp
        } else if fm.fileExists(atPath: Self.creatorStudioApp) {
            sourceApp = Self.creatorStudioApp
        } else {
            sourceApp = Self.standardApp
        }
        destDir = NSHomeDirectory() + "/Library/Application Support/SpliceKit"
        // Find sources: app bundle first, then Application Support cache
        var found = ""

        // 1. Embedded in app bundle (Resources/Sources/) — self-contained release
        if let resourcePath = Bundle.main.resourcePath {
            let embedded = resourcePath + "/Sources"
            if FileManager.default.fileExists(atPath: embedded + "/SpliceKit.m") {
                found = resourcePath
            }
        }

        // 2. Development: derive repo root from source file path (compile-time, no TCC prompt)
        #if DEBUG
        if found.isEmpty {
            let sourceFile = URL(fileURLWithPath: #filePath)
            let repoRoot = sourceFile
                .deletingLastPathComponent() // Models/
                .deletingLastPathComponent() // SpliceKit/
                .deletingLastPathComponent() // patcher/
                .deletingLastPathComponent() // repo root
                .path
            if FileManager.default.fileExists(atPath: repoRoot + "/Sources/SpliceKit.m") {
                found = repoRoot
            }
        }
        #endif

        // 3. Application Support cache (will download into it during patch)
        if found.isEmpty {
            found = NSHomeDirectory() + "/Library/Caches/SpliceKit"
        }
        repoDir = found
        // Defer status check — shell() pumps the run loop via waitUntilExit,
        // which crashes if called during SwiftUI view graph initialization.
        DispatchQueue.main.async { [self] in
            checkStatus()
            if status == .patched {
                currentPanel = .complete
            }
        }
    }

    func checkStatus() {
        let binary = moddedApp + "/Contents/MacOS/Final Cut Pro"
        if FileManager.default.fileExists(atPath: binary) {
            // Check if SpliceKit is injected
            let result = shell("otool -L '\(binary)' 2>/dev/null | grep SpliceKit")
            if result.contains("SpliceKit") {
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
        currentPanel = .patching

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
                    appendLog("SpliceKit connected on port 9876")
                } else {
                    appendLog("Waiting for SpliceKit... (check ~/Library/Logs/SpliceKit/splicekit.log)")
                }
            }
        }
    }

    func uninstall() {
        appendLog("Removing modded FCP...")
        shell("pkill -f 'Application Support/SpliceKit' 2>/dev/null; sleep 1")
        do {
            try FileManager.default.removeItem(atPath: destDir)
            appendLog("Removed \(destDir)")
            status = .notPatched
            bridgeConnected = false
            currentPanel = .welcome
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
            throw PatchError.msg("Xcode Command Line Tools are required.\n\nAn installer window should have appeared. Please complete the installation, then click \"Continue\" again.")
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

        let repoSources = repoDir + "/Sources/SpliceKit.m"
        if !FileManager.default.fileExists(atPath: repoSources) {
            await logAsync("Downloading SpliceKit sources...")
            let dlResult = shell("""
                mkdir -p '\(repoDir)' && \
                curl -sL https://github.com/elliotttate/FCPBridge/archive/refs/heads/main.zip \
                    -o /tmp/splicekit_src.zip && \
                unzip -qo /tmp/splicekit_src.zip -d /tmp/splicekit_extract && \
                cp -R /tmp/splicekit_extract/FCPBridge-main/* '\(repoDir)/' && \
                rm -rf /tmp/splicekit_src.zip /tmp/splicekit_extract 2>&1
                """)
            guard FileManager.default.fileExists(atPath: repoSources) else {
                throw PatchError.msg("Failed to download SpliceKit sources. Make sure you have an internet connection.\n\(dlResult)")
            }
            await logAsync("Downloaded SpliceKit sources")
        } else {
            await logAsync("SpliceKit sources: OK")
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
        let buildDir = NSTemporaryDirectory() + "SpliceKit_build"
        shell("mkdir -p '\(buildDir)'")

        // Check for pre-built dylib in app bundle (Xcode builds bundle it automatically)
        let bundledDylib = (Bundle.main.resourcePath ?? "") + "/SpliceKit"
        if FileManager.default.fileExists(atPath: bundledDylib) {
            await logAsync("Using pre-built SpliceKit dylib from app bundle")
            shell("cp '\(bundledDylib)' '\(buildDir)/SpliceKit'")
        } else {
            // Fallback: compile from source
            await logAsync("Compiling SpliceKit dylib...")
            let sources = ["SpliceKit.m", "SpliceKitRuntime.m", "SpliceKitSwizzle.m", "SpliceKitServer.m", "SpliceKitTranscriptPanel.m", "SpliceKitCommandPalette.m"]
                .map { "'\(repoDir)/Sources/\($0)'" }.joined(separator: " ")
            let buildResult = shell("""
                clang -arch arm64 -arch x86_64 -mmacosx-version-min=14.0 \
                -framework Foundation -framework AppKit -framework AVFoundation \
                -fobjc-arc -fmodules -Wno-deprecated-declarations \
                -undefined dynamic_lookup -dynamiclib \
                -install_name @rpath/SpliceKit.framework/Versions/A/SpliceKit \
                -I '\(repoDir)/Sources' \
                \(sources) -o '\(buildDir)/SpliceKit' 2>&1
                """)
            guard FileManager.default.fileExists(atPath: buildDir + "/SpliceKit") else {
                throw PatchError.msg("Build failed:\n\(buildResult)")
            }
            await logAsync("Built universal dylib (arm64 + x86_64)")
        }

        // Silence-detector: prefer pre-built from bundle
        let silenceBin = buildDir + "/silence-detector"
        let bundledSilence = (Bundle.main.resourcePath ?? "") + "/tools/silence-detector"
        if FileManager.default.fileExists(atPath: bundledSilence) {
            shell("cp '\(bundledSilence)' '\(silenceBin)'")
            await logAsync("Using pre-built silence-detector from app bundle")
        } else {
            let silenceSwift = repoDir + "/tools/silence-detector.swift"
            if FileManager.default.fileExists(atPath: silenceSwift) {
                _ = shell("swiftc -O -suppress-warnings -o '\(silenceBin)' '\(silenceSwift)' 2>&1")
                if FileManager.default.fileExists(atPath: silenceBin) {
                    await logAsync("Built silence-detector tool")
                } else {
                    await logAsync("Warning: silence-detector build failed (silence removal will be unavailable)")
                }
            }
        }

        // Parakeet-transcriber: prefer pre-built from bundle
        let parakeetBin = buildDir + "/parakeet-transcriber"
        let bundledParakeet = (Bundle.main.resourcePath ?? "") + "/tools/parakeet-transcriber"
        if FileManager.default.fileExists(atPath: bundledParakeet) {
            shell("cp '\(bundledParakeet)' '\(parakeetBin)'")
            await logAsync("Using pre-built Parakeet transcriber from app bundle")
        } else {
            let parakeetSrcDir = repoDir + "/tools/parakeet-transcriber"
            if FileManager.default.fileExists(atPath: parakeetSrcDir + "/Package.swift") {
                await logAsync("Building Parakeet transcriber (may take a moment on first run)...")
                let parakeetCacheDir = NSHomeDirectory() + "/Library/Caches/SpliceKit/tools/parakeet-transcriber"
                let sourcePath = URL(fileURLWithPath: parakeetSrcDir).standardizedFileURL.path
                let cachePath = URL(fileURLWithPath: parakeetCacheDir).standardizedFileURL.path
                let parakeetPkgDir: String
                if sourcePath == cachePath {
                    parakeetPkgDir = parakeetSrcDir
                } else {
                    await logAsync("Caching Parakeet transcriber sources...")
                    shell("""
                        rm -rf '\(parakeetCacheDir)' && \
                        mkdir -p '\((parakeetCacheDir as NSString).deletingLastPathComponent)' && \
                        ditto '\(parakeetSrcDir)' '\(parakeetCacheDir)' && \
                        rm -rf '\(parakeetCacheDir)/.build' '\(parakeetCacheDir)/.swiftpm' 2>&1
                        """)
                    parakeetPkgDir = parakeetCacheDir
                }
                let parakeetResult = shell("cd '\(parakeetPkgDir)' && swift build -c release 2>&1")
                let parakeetBuilt = parakeetPkgDir + "/.build/release/parakeet-transcriber"
                if FileManager.default.fileExists(atPath: parakeetBuilt) {
                    shell("cp '\(parakeetBuilt)' '\(parakeetBin)'")
                    await logAsync("Built Parakeet transcriber")
                } else {
                    await logAsync("Warning: Parakeet transcriber build failed (transcription will use Apple Speech instead)")
                    await logAsync(String(parakeetResult.suffix(200)))
                }
            }
        }

        await completeStepAsync(.buildDylib)

        // Step 4: Install framework
        await setStepAsync(.installFramework)
        let fwDir = moddedApp + "/Contents/Frameworks/SpliceKit.framework"
        shell("""
            mkdir -p '\(fwDir)/Versions/A/Resources'
            cp '\(buildDir)/SpliceKit' '\(fwDir)/Versions/A/SpliceKit'
            cd '\(fwDir)/Versions' && ln -sf A Current
            cd '\(fwDir)' && ln -sf Versions/Current/SpliceKit SpliceKit
            cd '\(fwDir)' && ln -sf Versions/Current/Resources Resources
            """)
        let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
            <key>CFBundleIdentifier</key><string>com.splicekit.SpliceKit</string>
            <key>CFBundleName</key><string>SpliceKit</string>
            <key>CFBundleVersion</key><string>2.6.1</string>
            <key>CFBundlePackageType</key><string>FMWK</string>
            <key>CFBundleExecutable</key><string>SpliceKit</string>
            </dict></plist>
            """
        try plist.write(toFile: fwDir + "/Versions/A/Resources/Info.plist", atomically: true, encoding: .utf8)

        // Deploy tools to Application Support
        let toolsDir = NSHomeDirectory() + "/Library/Application Support/SpliceKit/tools"
        shell("mkdir -p '\(toolsDir)'")
        if FileManager.default.fileExists(atPath: silenceBin) {
            shell("cp '\(silenceBin)' '\(toolsDir)/silence-detector'")
        }
        if FileManager.default.fileExists(atPath: parakeetBin) {
            shell("cp '\(parakeetBin)' '\(toolsDir)/parakeet-transcriber'")
        }
        // Also deploy parakeet-transcriber into the framework Resources so it's found first
        if FileManager.default.fileExists(atPath: parakeetBin) {
            shell("cp '\(parakeetBin)' '\(fwDir)/Versions/A/Resources/parakeet-transcriber'")
        }

        await logAsync("Framework installed")
        await completeStepAsync(.installFramework)

        // Step 5: Inject LC_LOAD_DYLIB
        await setStepAsync(.injectDylib)
        let binary = moddedApp + "/Contents/MacOS/Final Cut Pro"
        let alreadyInjected = shell("otool -L '\(binary)' 2>/dev/null | grep SpliceKit")
        if alreadyInjected.isEmpty {
            let insertDylib = "/tmp/splicekit_insert_dylib"
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
            shell("'\(insertDylib)' --inplace --all-yes '@rpath/SpliceKit.framework/Versions/A/SpliceKit' '\(binary)' 2>&1")
            await logAsync("Injected LC_LOAD_DYLIB")
        } else {
            await logAsync("Already injected (skipping)")
        }
        await completeStepAsync(.injectDylib)

        // Step 6: Re-sign
        await setStepAsync(.signApp)

        let signIdentity = "-"
        await logAsync("Using ad-hoc signature (preserves Apple framework signatures)")

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

        shell("/usr/libexec/PlistBuddy -c \"Add :NSSpeechRecognitionUsageDescription string 'SpliceKit uses speech recognition to transcribe timeline audio for text-based editing.'\" '\(moddedApp)/Contents/Info.plist' 2>/dev/null")

        shell("""
            codesign --force --sign \(signIdentity) '\(moddedApp)/Contents/Frameworks/SpliceKit.framework' 2>/dev/null
            codesign --force --sign \(signIdentity) --entitlements '\(entitlements)' '\(moddedApp)' 2>/dev/null
            """)

        let verify = shell("codesign --verify --verbose '\(moddedApp)' 2>&1")
        if verify.contains("valid") || verify.contains("satisfies") {
            await logAsync("Signature verified")
        } else {
            await logAsync("Signature note: \(verify)")
        }

        shell("tccutil reset All com.apple.FinalCut 2>/dev/null")
        await logAsync("Reset permissions for new signature")
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
        await logAsync("\nSetup complete! You can now launch the enhanced Final Cut Pro.")
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

    func appendLog(_ text: String) {
        log += text + "\n"
    }

    private nonisolated func logAsync(_ text: String) async {
        await MainActor.run { self.log += text + "\n" }
    }

    private nonisolated func setStepAsync(_ step: PatchStep) async {
        await MainActor.run { self.currentStep = step }
    }

    private nonisolated func completeStepAsync(_ step: PatchStep) async {
        await MainActor.run { _ = self.completedSteps.insert(step) }
    }
}
