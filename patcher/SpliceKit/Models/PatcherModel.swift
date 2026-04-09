// PatcherModel.swift -- Core model for the SpliceKit GUI patcher.
// Drives the wizard-style UI: welcome -> patching -> complete.
// Handles FCP edition detection, patch orchestration, and launch.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Types

enum InstallState: Equatable {
    case notInstalled       // No modded FCP found
    case current            // Installed, framework matches patcher's build
    case updateAvailable    // SpliceKit framework differs from patcher's build
    case fcpUpdateAvailable // Stock FCP version changed since modded copy was made
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

/// The three panels of the wizard-style patcher UI.
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
    @Published var status: InstallState = .unknown
    @Published var currentStep: PatchStep?
    @Published var completedSteps: Set<PatchStep> = []
    @Published var log: String = ""
    @Published var isPatching = false
    @Published var isPatchComplete = false
    @Published var errorMessage: String?
    @Published var fcpVersion: String = ""
    @Published var stockFcpVersion: String = ""
    @Published var bridgeConnected = false
    @Published var isUpdateMode = false
    @Published var currentPanel: WizardPanel = .welcome

    static let standardApp = "/Applications/Final Cut Pro.app"
    static let creatorStudioApp = "/Applications/Final Cut Pro Creator Studio.app"

    @Published var sourceApp: String   // path to the stock FCP.app
    let destDir: String                // ~/Applications/SpliceKit/
    var moddedApp: String { destDir + "/" + (sourceApp as NSString).lastPathComponent }
    let repoDir: String                // where SpliceKit sources live

    /// Which FCP editions are installed (standard, Creator Studio, or auto-discovered)
    var availableEditions: [(label: String, path: String)] {
        var editions: [(String, String)] = []
        let knownPaths: Set<String> = [Self.standardApp, Self.creatorStudioApp]
        if FileManager.default.fileExists(atPath: Self.standardApp) {
            editions.append(("Final Cut Pro", Self.standardApp))
        }
        if FileManager.default.fileExists(atPath: Self.creatorStudioApp) {
            editions.append(("Final Cut Pro Creator Studio", Self.creatorStudioApp))
        }
        // Include user-browsed or auto-discovered path if not already listed
        if !knownPaths.contains(sourceApp) && FileManager.default.fileExists(atPath: sourceApp + "/Contents/Info.plist") {
            let name = (sourceApp as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
            editions.append((name, sourceApp))
        }
        return editions
    }

    var hasBothEditions: Bool { availableEditions.count > 1 }

    /// True when sourceApp points to an existing FCP bundle (standard path or user-browsed).
    var fcpFound: Bool { FileManager.default.fileExists(atPath: sourceApp + "/Contents/Info.plist") }

    func switchEdition(to path: String) {
        sourceApp = path
        fcpVersion = ""
        checkStatus()
    }

    /// Open a file browser so the user can locate Final Cut Pro manually.
    func browseForFCP() {
        let panel = NSOpenPanel()
        panel.title = "Locate Final Cut Pro"
        panel.message = "Select your Final Cut Pro application"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")

        guard panel.runModal() == .OK, let url = panel.url else { return }

        // Validate it's actually Final Cut Pro
        let plistPath = url.appendingPathComponent("Contents/Info.plist").path
        let bundleID = shell("/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' '\(plistPath)' 2>/dev/null")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let bundleName = shell("/usr/libexec/PlistBuddy -c 'Print :CFBundleName' '\(plistPath)' 2>/dev/null")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard bundleID == "com.apple.FinalCut" || bundleName.contains("Final Cut") else {
            errorMessage = "The selected app does not appear to be Final Cut Pro."
            return
        }

        errorMessage = nil
        sourceApp = url.path
        fcpVersion = ""
        checkStatus()
    }

    /// Use Spotlight to find Final Cut Pro anywhere on the system.
    private static func findFCPViaSpotlight() -> String? {
        let p = Process()
        let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        p.arguments = ["kMDItemCFBundleIdentifier == 'com.apple.FinalCut'"]
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let paths = (String(data: data, encoding: .utf8) ?? "")
            .split(separator: "\n")
            .map(String.init)
        // Prefer paths in /Applications, skip any in ~/Applications/SpliceKit (our modded copy)
        let spliceKitDir = NSHomeDirectory() + "/Applications/SpliceKit"
        return paths.first { $0.hasPrefix("/Applications/") }
            ?? paths.first { !$0.hasPrefix(spliceKitDir) }
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
        destDir = NSHomeDirectory() + "/Applications/SpliceKit"

        var found = ""

        // 1. Embedded in app bundle (Resources/Sources/)
        if let resourcePath = Bundle.main.resourcePath {
            let embedded = resourcePath + "/Sources"
            if fm.fileExists(atPath: embedded + "/SpliceKit.m") {
                found = resourcePath
            }
        }

        // 2. Development: derive repo root from source file path
        #if DEBUG
        if found.isEmpty {
            let sourceFile = URL(fileURLWithPath: #filePath)
            let repoRoot = sourceFile
                .deletingLastPathComponent() // Models/
                .deletingLastPathComponent() // SpliceKit/
                .deletingLastPathComponent() // patcher/
                .deletingLastPathComponent() // repo root
                .path
            if fm.fileExists(atPath: repoRoot + "/Sources/SpliceKit.m") {
                found = repoRoot
            }
        }
        #endif

        // 3. Cache dir (will download into it during patch)
        if found.isEmpty {
            found = NSHomeDirectory() + "/Library/Caches/SpliceKit"
        }
        repoDir = found

        // Defer shell calls -- waitUntilExit pumps the run loop, which crashes
        // if called during SwiftUI view graph initialization.
        DispatchQueue.main.async { [self] in
            // Search for FCP via Spotlight if not at standard paths
            if !fcpFound, let found = Self.findFCPViaSpotlight() {
                sourceApp = found
            }
            checkStatus()
            if status != .notInstalled && status != .unknown {
                currentPanel = .complete
            }
        }
    }

    /// Evaluate install state: is SpliceKit injected? Is it the current build? Is FCP up to date?
    func checkStatus() {
        let binary = moddedApp + "/Contents/MacOS/Final Cut Pro"
        let installedDylib = moddedApp + "/Contents/Frameworks/SpliceKit.framework/Versions/A/SpliceKit"

        // Read stock FCP version (also shown on the welcome panel)
        stockFcpVersion = readPlistVersion(sourceApp)
        if fcpVersion.isEmpty { fcpVersion = stockFcpVersion }

        // Q1: Is a modded FCP present with the SpliceKit load command?
        guard FileManager.default.fileExists(atPath: binary) else {
            status = .notInstalled
            bridgeConnected = false
            return
        }
        let otoolResult = shell("otool -L '\(binary)' 2>/dev/null | grep '@rpath/SpliceKit'")
        guard !otoolResult.isEmpty else {
            status = .notInstalled
            bridgeConnected = false
            return
        }

        // Bridge check
        let ps = shell("lsof -i :9876 2>/dev/null | grep LISTEN")
        bridgeConnected = !ps.isEmpty

        // Read modded FCP version
        let moddedVer = readPlistVersion(moddedApp)
        if !moddedVer.isEmpty { fcpVersion = moddedVer }

        // Q2a: Has stock FCP been updated since the modded copy was made?
        if !stockFcpVersion.isEmpty && !moddedVer.isEmpty && stockFcpVersion != moddedVer {
            status = .fcpUpdateAvailable
            return
        }

        // Q2b: Does the installed SpliceKit binary match the patcher's build?
        let bundledDylib = (Bundle.main.resourcePath ?? "") + "/SpliceKit"
        if FileManager.default.fileExists(atPath: bundledDylib),
           FileManager.default.fileExists(atPath: installedDylib) {
            let bundledHash = fileHash(bundledDylib)
            let installedHash = fileHash(installedDylib)
            if !bundledHash.isEmpty && !installedHash.isEmpty && bundledHash != installedHash {
                status = .updateAvailable
                return
            }
        }

        status = .current
    }

    func patch() {
        guard !isPatching else { return }
        isPatching = true
        isUpdateMode = false
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
                    self.status = .current
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
        shell("pkill -f 'Applications/SpliceKit' 2>/dev/null; sleep 1")
        do {
            try FileManager.default.removeItem(atPath: destDir)
            appendLog("Removed \(destDir)")
            status = .notInstalled
            bridgeConnected = false
            currentPanel = .welcome
        } catch {
            appendLog("Error: \(error.localizedDescription)")
        }
    }

    /// In-place framework update: rebuild dylib + tools, re-sign. No FCP re-copy needed.
    func updateSpliceKit() {
        guard !isPatching else { return }
        isPatching = true
        isUpdateMode = true
        isPatchComplete = false
        errorMessage = nil
        log = ""
        completedSteps = []
        currentPanel = .patching

        Task.detached { [self] in
            do {
                try await self.runUpdate()
                await MainActor.run {
                    self.isPatchComplete = true
                    self.status = .current
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.appendLog("ERROR: \(error.localizedDescription)")
                }
            }
            await MainActor.run {
                self.isPatching = false
                self.isUpdateMode = false
            }
        }
    }

    /// Delete the modded FCP and re-patch from the current stock FCP.
    func rebuildModdedApp() {
        guard !isPatching else { return }
        appendLog("Removing old modded FCP for rebuild...")
        shell("pkill -f 'Applications/SpliceKit' 2>/dev/null; sleep 1")
        try? FileManager.default.removeItem(atPath: moddedApp)
        bridgeConnected = false
        patch()
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
                curl -sL https://github.com/elliotttate/SpliceKit/archive/refs/heads/main.zip \
                    -o /tmp/splicekit_src.zip && \
                unzip -qo /tmp/splicekit_src.zip -d /tmp/splicekit_extract && \
                cp -R /tmp/splicekit_extract/SpliceKit-main/* '\(repoDir)/' && \
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

        // Step 2: Copy FCP bundle, preserve MAS receipt, strip quarantine xattrs
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

        // Step 3: Build dylib and companion tools (prefers pre-built from app bundle)
        await setStepAsync(.buildDylib)
        let buildDir = NSTemporaryDirectory() + "SpliceKit_build"
        shell("mkdir -p '\(buildDir)'")

        let bundledDylib = (Bundle.main.resourcePath ?? "") + "/SpliceKit"
        if FileManager.default.fileExists(atPath: bundledDylib) {
            await logAsync("Using pre-built SpliceKit dylib from app bundle")
            shell("cp '\(bundledDylib)' '\(buildDir)/SpliceKit'")
        } else {
            await logAsync("Compiling SpliceKit dylib...")
            let sources = ["SpliceKit.m", "SpliceKitRuntime.m", "SpliceKitSwizzle.m", "SpliceKitServer.m", "SpliceKitLogPanel.m", "SpliceKitTranscriptPanel.m", "SpliceKitCaptionPanel.m", "SpliceKitCommandPalette.m", "SpliceKitDebugUI.m"]
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

        // Build tools
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

        let parakeetBin = buildDir + "/parakeet-transcriber"
        let bundledParakeet = (Bundle.main.resourcePath ?? "") + "/tools/parakeet-transcriber"
        var bundledParakeetIsDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: bundledParakeet, isDirectory: &bundledParakeetIsDirectory),
           !bundledParakeetIsDirectory.boolValue {
            shell("cp '\(bundledParakeet)' '\(parakeetBin)'")
            await logAsync("Using pre-built Parakeet transcriber from app bundle")
        } else {
            let bundledParakeetSources = bundledParakeetIsDirectory.boolValue ? bundledParakeet : ""
            let parakeetSrcDir = FileManager.default.fileExists(atPath: bundledParakeetSources + "/Package.swift")
                ? bundledParakeetSources
                : repoDir + "/patcher/SpliceKitPatcher.app/Contents/Resources/tools/parakeet-transcriber"
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

        // Step 4: Create macOS framework bundle (Versions/A + symlinks)
        await setStepAsync(.installFramework)
        let fwDir = moddedApp + "/Contents/Frameworks/SpliceKit.framework"
        shell("""
            mkdir -p '\(fwDir)/Versions/A/Resources'
            cp '\(buildDir)/SpliceKit' '\(fwDir)/Versions/A/SpliceKit'
            cd '\(fwDir)/Versions' && ln -sf A Current
            cd '\(fwDir)' && ln -sf Versions/Current/SpliceKit SpliceKit
            cd '\(fwDir)' && ln -sf Versions/Current/Resources Resources
            """)
        let patcherVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
            <key>CFBundleIdentifier</key><string>com.splicekit.SpliceKit</string>
            <key>CFBundleName</key><string>SpliceKit</string>
            <key>CFBundleVersion</key><string>\(patcherVersion)</string>
            <key>CFBundlePackageType</key><string>FMWK</string>
            <key>CFBundleExecutable</key><string>SpliceKit</string>
            </dict></plist>
            """
        try plist.write(toFile: fwDir + "/Versions/A/Resources/Info.plist", atomically: true, encoding: .utf8)

        // Deploy tools
        let toolsDir = NSHomeDirectory() + "/Applications/SpliceKit/tools"
        shell("mkdir -p '\(toolsDir)'")
        if FileManager.default.fileExists(atPath: silenceBin) {
            shell("cp '\(silenceBin)' '\(toolsDir)/silence-detector'")
        }
        if FileManager.default.fileExists(atPath: parakeetBin) {
            shell("cp '\(parakeetBin)' '\(toolsDir)/parakeet-transcriber'")
        }

        await logAsync("Framework installed")
        await completeStepAsync(.installFramework)

        // Step 5: Patch the Mach-O binary so dyld loads SpliceKit on launch
        await setStepAsync(.injectDylib)
        let binary = moddedApp + "/Contents/MacOS/Final Cut Pro"
        let alreadyInjected = shell("otool -L '\(binary)' 2>/dev/null | grep '@rpath/SpliceKit'")
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

        // Step 6: Re-sign the wrapper and SpliceKit.framework only.
        // Apple frameworks keep their original signatures to avoid integrity check failures.
        await setStepAsync(.signApp)
        var signIdentity = preferredSigningIdentity() ?? "-"
        if signIdentity == "-" {
            await logAsync("No local codesigning identity found; using ad-hoc signature (higher risk of macOS launch/security blocks)")
        } else {
            await logAsync("Using signing identity: \(signIdentity)")
        }
        let entitlements = buildDir + "/entitlements.plist"
        let entPlist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
            <key>com.apple.security.cs-disable-library-validation</key><true/>
            </dict></plist>
            """
        try entPlist.write(toFile: entitlements, atomically: true, encoding: .utf8)

        shell("/usr/libexec/PlistBuddy -c \"Add :NSSpeechRecognitionUsageDescription string 'SpliceKit uses speech recognition to transcribe timeline audio for text-based editing.'\" '\(moddedApp)/Contents/Info.plist' 2>/dev/null")

        let quotedIdentity = shellQuote(signIdentity)
        var signResult = shellResult("""
            codesign --force --sign \(quotedIdentity) '\(moddedApp)/Contents/Frameworks/SpliceKit.framework' 2>&1 && \
            codesign --force --sign \(quotedIdentity) --entitlements '\(entitlements)' '\(moddedApp)' 2>&1
            """)
        if signResult.status != 0 && signIdentity != "-" {
            await logAsync("Developer signing failed; retrying with ad-hoc signature (higher risk of macOS launch/security blocks)")
            if !signResult.output.isEmpty {
                await logAsync(String(signResult.output.suffix(400)))
            }
            signIdentity = "-"
            signResult = shellResult("""
                codesign --force --sign - '\(moddedApp)/Contents/Frameworks/SpliceKit.framework' 2>&1 && \
                codesign --force --sign - --entitlements '\(entitlements)' '\(moddedApp)' 2>&1
                """)
        }
        guard signResult.status == 0 else {
            throw PatchError.msg("Signing failed:\n\(signResult.output)")
        }
        if signIdentity == "-" {
            await logAsync("Applied ad-hoc signature")
        } else {
            await logAsync("Applied signature: \(signIdentity)")
        }

        let verify = shell("codesign --verify --verbose '\(moddedApp)' 2>&1")
        if verify.contains("valid") || verify.contains("satisfies") {
            await logAsync("Signature verified")
        } else {
            await logAsync("Signature note: \(verify)")
        }
        await completeStepAsync(.signApp)

        // Step 7: Skip FCP's first-launch cloud content download dialog
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

    /// Update path: rebuild framework + tools, re-sign. Skips FCP copy and dylib injection.
    private nonisolated func runUpdate() async throws {
        let repoDir = await MainActor.run { self.repoDir }
        let moddedApp = await MainActor.run { self.moddedApp }

        // Mark skipped steps as complete
        await completeStepAsync(.checkPrereqs)
        await completeStepAsync(.copyApp)

        // Build dylib
        await setStepAsync(.buildDylib)
        let buildDir = NSTemporaryDirectory() + "SpliceKit_build"
        shell("mkdir -p '\(buildDir)'")

        let bundledDylib = (Bundle.main.resourcePath ?? "") + "/SpliceKit"
        if FileManager.default.fileExists(atPath: bundledDylib) {
            await logAsync("Using pre-built SpliceKit dylib from app bundle")
            shell("cp '\(bundledDylib)' '\(buildDir)/SpliceKit'")
        } else {
            await logAsync("Compiling SpliceKit dylib...")
            let sources = ["SpliceKit.m", "SpliceKitRuntime.m", "SpliceKitSwizzle.m", "SpliceKitServer.m", "SpliceKitLogPanel.m", "SpliceKitTranscriptPanel.m", "SpliceKitCaptionPanel.m", "SpliceKitCommandPalette.m", "SpliceKitDebugUI.m"]
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

        // Build tools
        let silenceBin = buildDir + "/silence-detector"
        let bundledSilence = (Bundle.main.resourcePath ?? "") + "/tools/silence-detector"
        if FileManager.default.fileExists(atPath: bundledSilence) {
            shell("cp '\(bundledSilence)' '\(silenceBin)'")
        } else {
            let silenceSwift = repoDir + "/tools/silence-detector.swift"
            if FileManager.default.fileExists(atPath: silenceSwift) {
                _ = shell("swiftc -O -suppress-warnings -o '\(silenceBin)' '\(silenceSwift)' 2>&1")
            }
        }

        let parakeetBin = buildDir + "/parakeet-transcriber"
        let bundledParakeet = (Bundle.main.resourcePath ?? "") + "/tools/parakeet-transcriber"
        var bundledParakeetIsDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: bundledParakeet, isDirectory: &bundledParakeetIsDirectory),
           !bundledParakeetIsDirectory.boolValue {
            shell("cp '\(bundledParakeet)' '\(parakeetBin)'")
        } else {
            let bundledParakeetSources = bundledParakeetIsDirectory.boolValue ? bundledParakeet : ""
            let parakeetSrcDir = FileManager.default.fileExists(atPath: bundledParakeetSources + "/Package.swift")
                ? bundledParakeetSources
                : repoDir + "/patcher/SpliceKitPatcher.app/Contents/Resources/tools/parakeet-transcriber"
            if FileManager.default.fileExists(atPath: parakeetSrcDir + "/Package.swift") {
                let parakeetCacheDir = NSHomeDirectory() + "/Library/Caches/SpliceKit/tools/parakeet-transcriber"
                let sourcePath = URL(fileURLWithPath: parakeetSrcDir).standardizedFileURL.path
                let cachePath = URL(fileURLWithPath: parakeetCacheDir).standardizedFileURL.path
                let parakeetPkgDir: String
                if sourcePath == cachePath {
                    parakeetPkgDir = parakeetSrcDir
                } else {
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
                }
            }
        }
        await completeStepAsync(.buildDylib)

        // Install framework (overwrite existing binary)
        await setStepAsync(.installFramework)
        let fwDir = moddedApp + "/Contents/Frameworks/SpliceKit.framework"
        shell("cp '\(buildDir)/SpliceKit' '\(fwDir)/Versions/A/SpliceKit'")

        let patcherVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
            <key>CFBundleIdentifier</key><string>com.splicekit.SpliceKit</string>
            <key>CFBundleName</key><string>SpliceKit</string>
            <key>CFBundleVersion</key><string>\(patcherVersion)</string>
            <key>CFBundlePackageType</key><string>FMWK</string>
            <key>CFBundleExecutable</key><string>SpliceKit</string>
            </dict></plist>
            """
        try plist.write(toFile: fwDir + "/Versions/A/Resources/Info.plist", atomically: true, encoding: .utf8)

        // Deploy tools
        let toolsDir = NSHomeDirectory() + "/Applications/SpliceKit/tools"
        shell("mkdir -p '\(toolsDir)'")
        if FileManager.default.fileExists(atPath: silenceBin) {
            shell("cp '\(silenceBin)' '\(toolsDir)/silence-detector'")
        }
        if FileManager.default.fileExists(atPath: parakeetBin) {
            shell("cp '\(parakeetBin)' '\(toolsDir)/parakeet-transcriber'")
        }

        await logAsync("Framework updated")
        await completeStepAsync(.installFramework)

        // Skip inject (load command already present)
        await completeStepAsync(.injectDylib)

        // Re-sign
        await setStepAsync(.signApp)
        var signIdentity = preferredSigningIdentity() ?? "-"
        if signIdentity == "-" {
            await logAsync("No local codesigning identity found; using ad-hoc signature (higher risk of macOS launch/security blocks)")
        } else {
            await logAsync("Using signing identity: \(signIdentity)")
        }
        let entitlements = buildDir + "/entitlements.plist"
        let entPlist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
            <key>com.apple.security.cs-disable-library-validation</key><true/>
            </dict></plist>
            """
        try entPlist.write(toFile: entitlements, atomically: true, encoding: .utf8)

        let quotedIdentity = shellQuote(signIdentity)
        var signResult = shellResult("""
            codesign --force --sign \(quotedIdentity) '\(moddedApp)/Contents/Frameworks/SpliceKit.framework' 2>&1 && \
            codesign --force --sign \(quotedIdentity) --entitlements '\(entitlements)' '\(moddedApp)' 2>&1
            """)
        if signResult.status != 0 && signIdentity != "-" {
            await logAsync("Developer signing failed; retrying with ad-hoc signature (higher risk of macOS launch/security blocks)")
            if !signResult.output.isEmpty {
                await logAsync(String(signResult.output.suffix(400)))
            }
            signIdentity = "-"
            signResult = shellResult("""
                codesign --force --sign - '\(moddedApp)/Contents/Frameworks/SpliceKit.framework' 2>&1 && \
                codesign --force --sign - --entitlements '\(entitlements)' '\(moddedApp)' 2>&1
                """)
        }
        guard signResult.status == 0 else {
            throw PatchError.msg("Signing failed:\n\(signResult.output)")
        }
        if signIdentity == "-" {
            await logAsync("Applied ad-hoc signature")
        } else {
            await logAsync("Applied signature: \(signIdentity)")
        }

        let verify = shell("codesign --verify --verbose '\(moddedApp)' 2>&1")
        if verify.contains("valid") || verify.contains("satisfies") {
            await logAsync("Signature verified")
        } else {
            await logAsync("Signature note: \(verify)")
        }
        await completeStepAsync(.signApp)

        await completeStepAsync(.configureDefaults)
        await completeStepAsync(.setupMCP)

        await setStepAsync(.done)
        await logAsync("\nSpliceKit updated! You can now launch Final Cut Pro.")
    }

    // MARK: - Helpers

    /// SHA-256 hash of a file on disk.
    nonisolated func fileHash(_ path: String) -> String {
        shell("shasum -a 256 '\(path)' 2>/dev/null | awk '{print $1}'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Read CFBundleShortVersionString from an app bundle's Info.plist.
    private nonisolated func readPlistVersion(_ appPath: String) -> String {
        let ver = shell("/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' '\(appPath)/Contents/Info.plist' 2>/dev/null")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (ver.isEmpty || ver.contains("Doesn't Exist")) ? "" : ver
    }

    /// Run a shell command synchronously; nonisolated for use in background tasks.
    nonisolated func shellResult(_ command: String) -> (output: String, status: Int32) {
        let process = Process()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        try? process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (String(data: data, encoding: .utf8) ?? "", process.terminationStatus)
    }

    @discardableResult
    nonisolated func shell(_ command: String) -> String {
        shellResult(command).output
    }

    private nonisolated func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private nonisolated func preferredSigningIdentity() -> String? {
        let output = shell("/usr/bin/security find-identity -v -p codesigning 2>/dev/null")
        let identities = output
            .split(separator: "\n")
            .compactMap { line -> (hash: String, label: String)? in
                let parts = line.split(omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
                guard parts.count >= 3,
                      let firstQuote = line.firstIndex(of: "\""),
                      let lastQuote = line.lastIndex(of: "\""),
                      firstQuote != lastQuote else {
                    return nil
                }
                return (
                    hash: String(parts[1]),
                    label: String(line[line.index(after: firstQuote)..<lastQuote])
                )
            }

        if let identity = identities.first(where: { $0.label.hasPrefix("Apple Development:") }) {
            return identity.hash
        }
        if let identity = identities.first(where: { $0.label.hasPrefix("Developer ID Application:") }) {
            return identity.hash
        }
        return identities.first?.hash
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
