// PatcherModel.swift -- Core model for the SpliceKit GUI patcher.
// Drives the wizard-style UI: welcome -> patching -> complete.
// Handles FCP edition detection, patch orchestration, and launch.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Types

enum InstallState: Equatable {
    case notInstalled       // No modded FCP found
    case current            // Installed, framework version matches patcher's build
    case updateAvailable    // SpliceKit framework version differs from patcher's build
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

// MARK: - Patcher Log File
//
// Writes to ~/Library/Logs/SpliceKit/patcher.log so we have a persistent record
// of every patch attempt — even if FCP crashes on launch and the dylib never loads.

private let patcherLogURL: URL = {
    let logDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/SpliceKit")
    try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
    let logFile = logDir.appendingPathComponent("patcher.log")
    // Rotate: keep one previous log
    let prev = logDir.appendingPathComponent("patcher.previous.log")
    try? FileManager.default.removeItem(at: prev)
    try? FileManager.default.moveItem(at: logFile, to: prev)
    FileManager.default.createFile(atPath: logFile.path, contents: nil)
    return logFile
}()

private func patcherLogWrite(_ text: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(timestamp)] \(text)\n"
    if let handle = try? FileHandle(forWritingTo: patcherLogURL) {
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8) ?? Data())
        handle.closeFile()
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

    private var launchedFCPProcess: Process?
    private var launchMonitorTask: Task<Void, Never>?

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

        // The app ships a pre-built dylib in Resources/. No source compilation needed.
        // repoDir points to the app bundle's Resources, which contains the pre-built
        // dylib and tools that get copied into the modded FCP during patching.
        repoDir = Bundle.main.resourcePath ?? NSHomeDirectory() + "/Library/Caches/SpliceKit"

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
        let installedFramework = moddedApp + "/Contents/Frameworks/SpliceKit.framework"

        // Read stock FCP version (also shown on the welcome panel)
        stockFcpVersion = readBundleVersion(sourceApp)
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
        let moddedVer = readBundleVersion(moddedApp)
        if !moddedVer.isEmpty { fcpVersion = moddedVer }

        // Q2a: Has stock FCP been updated since the modded copy was made?
        if !stockFcpVersion.isEmpty && !moddedVer.isEmpty && stockFcpVersion != moddedVer {
            status = .fcpUpdateAvailable
            return
        }

        // Q2b: Does the installed SpliceKit framework version match this patcher build?
        // Compare metadata instead of the binary bytes: the installed framework is re-signed
        // during patch/update, which changes its on-disk hash even when the code is current.
        let installedFrameworkVersion = readBundleVersion(installedFramework)
        let patcherVersion = currentSpliceKitVersion()
        if !patcherVersion.isEmpty {
            if installedFrameworkVersion.isEmpty || installedFrameworkVersion != patcherVersion {
                status = .updateAvailable
                return
            }
        }

        status = .current
    }

    /// Lightweight poll of the bridge connection state. Runs the `lsof` probe
    /// off the main thread and only updates `bridgeConnected` when it actually
    /// changes, so the StatusPanel's indicator light reflects FCP's live state
    /// without the user having to hit Refresh.
    func pollBridgeStatus() async {
        let connected: Bool = await Task.detached {
            let r = shell("lsof -i :9876 2>/dev/null | grep LISTEN")
            return !r.isEmpty
        }.value

        if connected != bridgeConnected {
            bridgeConnected = connected
        }
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
        let launchTime = Date()
        let spliceKitLogURL = runtimeLogURL(named: "splicekit.log")
        let spliceKitLogDateBeforeLaunch = fileModificationDate(at: spliceKitLogURL)
        let cloudContentSnapshot = configureCloudContentDefaults(for: moddedApp)

        launchMonitorTask?.cancel()
        appendLog("Launching modded FCP...")
        appendLog("Launch binary: \(binary)")
        appendLog("CloudContent defaults: \(cloudContentSnapshot)")
        if let previousLogDate = spliceKitLogDateBeforeLaunch {
            appendLog("Existing SpliceKit log mtime before launch: \(iso8601(previousLogDate))")
        } else {
            appendLog("Existing SpliceKit log mtime before launch: none")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                self?.handleLaunchTermination(
                    process: proc,
                    launchTime: launchTime,
                    spliceKitLogDateBeforeLaunch: spliceKitLogDateBeforeLaunch
                )
            }
        }
        do {
            try process.run()
            launchedFCPProcess = process
            appendLog("Spawned Final Cut Pro pid \(process.processIdentifier)")
        } catch {
            launchedFCPProcess = nil
            appendLog("Failed to launch Final Cut Pro: \(error.localizedDescription)")
            return
        }

        launchMonitorTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard let self, !Task.isCancelled else { return }
            self.checkStatus()
            if self.bridgeConnected {
                self.appendLog("SpliceKit connected on port 9876")
                let diagnostics = self.launchDiagnostics(
                    launchTime: launchTime,
                    spliceKitLogDateBeforeLaunch: spliceKitLogDateBeforeLaunch
                )
                if let first = diagnostics.first {
                    self.appendLog(first)
                }
            } else {
                self.appendLog("Bridge not ready after 12s")
                for line in self.launchDiagnostics(
                    launchTime: launchTime,
                    spliceKitLogDateBeforeLaunch: spliceKitLogDateBeforeLaunch
                ) {
                    self.appendLog(line)
                }
                if self.launchedFCPProcess?.isRunning == true {
                    self.appendLog("Final Cut Pro is still running, but the SpliceKit bridge is not listening yet.")
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

        // Use pre-built dylib from app bundle
        let bundledDylib = (Bundle.main.resourcePath ?? "") + "/SpliceKit"
        guard FileManager.default.fileExists(atPath: bundledDylib) else {
            throw PatchError.msg("Pre-built SpliceKit dylib not found in app bundle. Please re-download the patcher app.")
        }
        await logAsync("Using pre-built SpliceKit dylib")
        shell("cp '\(bundledDylib)' '\(buildDir)/SpliceKit'")

        // Copy pre-built tools from app bundle
        let silenceBin = buildDir + "/silence-detector"
        let bundledSilence = (Bundle.main.resourcePath ?? "") + "/tools/silence-detector"
        if FileManager.default.fileExists(atPath: bundledSilence) {
            shell("cp '\(bundledSilence)' '\(silenceBin)'")
        }

        let parakeetBin = buildDir + "/parakeet-transcriber"
        let bundledParakeet = (Bundle.main.resourcePath ?? "") + "/tools/parakeet-transcriber"
        if FileManager.default.fileExists(atPath: bundledParakeet) {
            shell("cp '\(bundledParakeet)' '\(parakeetBin)'")
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
        let currentVersion = currentSpliceKitVersion()
        let patcherVersion = currentVersion.isEmpty ? "0.0.0" : currentVersion
        let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
            <key>CFBundleIdentifier</key><string>com.splicekit.SpliceKit</string>
            <key>CFBundleName</key><string>SpliceKit</string>
            <key>CFBundleShortVersionString</key><string>\(patcherVersion)</string>
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
            <key>com.apple.security.app-sandbox</key><false/>
            <key>com.apple.security.cs.disable-library-validation</key><true/>
            <key>com.apple.security.cs.allow-dyld-environment-variables</key><true/>
            <key>com.apple.security.get-task-allow</key><true/>
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
        let cloudContentSnapshot = configureCloudContentDefaults(for: moddedApp)
        await logAsync("CloudContent defaults configured: \(cloudContentSnapshot)")
        await completeStepAsync(.configureDefaults)

        // Step 8: MCP
        await setStepAsync(.setupMCP)
        let mcpServer = repoDir + "/mcp/server.py"
        if FileManager.default.fileExists(atPath: mcpServer) {
            await logAsync("MCP server: \(mcpServer)")
        }
        await completeStepAsync(.setupMCP)

        // Post-patch diagnostics — verify everything a user would need for bug reports
        await logAsync("\n--- Post-Patch Diagnostics ---")
        let osv = ProcessInfo.processInfo.operatingSystemVersion
        await logAsync("macOS: \(osv.majorVersion).\(osv.minorVersion).\(osv.patchVersion)")
        let fcpInfo = NSDictionary(contentsOfFile: moddedApp + "/Contents/Info.plist")
        await logAsync("FCP: \(fcpInfo?["CFBundleShortVersionString"] ?? "?") (build \(fcpInfo?["CFBundleVersion"] ?? "?"))")
        await logAsync("SpliceKit patcher: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?")")
        await logAsync("Signing identity used: \(signIdentity)")

        // Verify load command injection
        let otoolOut = shell("otool -L '\(moddedApp)/Contents/MacOS/Final Cut Pro' 2>&1 | grep -i splice")
        if otoolOut.isEmpty {
            await logAsync("WARNING: SpliceKit load command NOT found in binary (dylib will NOT load)")
        } else {
            await logAsync("Load command: \(otoolOut.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        // Verify framework binary exists
        let fwBinary = moddedApp + "/Contents/Frameworks/SpliceKit.framework/Versions/A/SpliceKit"
        if FileManager.default.fileExists(atPath: fwBinary) {
            let attrs = try? FileManager.default.attributesOfItem(atPath: fwBinary)
            let size = (attrs?[.size] as? Int) ?? 0
            await logAsync("Framework binary: exists (\(size) bytes)")
        } else {
            await logAsync("WARNING: Framework binary NOT found at \(fwBinary)")
        }

        // Verify framework signature
        let fwVerify = shell("codesign -dvv '\(moddedApp)/Contents/Frameworks/SpliceKit.framework' 2>&1")
        for line in fwVerify.components(separatedBy: "\n") where line.contains("Authority=") || line.contains("TeamIdentifier=") || line.contains("Signature=") {
            await logAsync("Framework signing: \(line.trimmingCharacters(in: .whitespaces))")
        }

        // Verify app entitlements
        let entOut = shell("codesign -d --entitlements - '\(moddedApp)' 2>&1")
        let entKeys = ["app-sandbox", "disable-library-validation", "allow-dyld-environment-variables", "get-task-allow", "icloud-services"]
        for key in entKeys {
            let found = entOut.contains(key)
            await logAsync("Entitlement \(key): \(found ? "present" : "MISSING")")
        }

        await logAsync("Log saved to: ~/Library/Logs/SpliceKit/patcher.log")
        await logAsync("--- End Diagnostics ---")

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

        // Use pre-built dylib from app bundle
        let bundledDylib = (Bundle.main.resourcePath ?? "") + "/SpliceKit"
        guard FileManager.default.fileExists(atPath: bundledDylib) else {
            throw PatchError.msg("Pre-built SpliceKit dylib not found in app bundle. Please re-download the patcher app.")
        }
        await logAsync("Using pre-built SpliceKit dylib")
        shell("cp '\(bundledDylib)' '\(buildDir)/SpliceKit'")

        // Copy pre-built tools from app bundle
        let silenceBin = buildDir + "/silence-detector"
        let bundledSilence = (Bundle.main.resourcePath ?? "") + "/tools/silence-detector"
        if FileManager.default.fileExists(atPath: bundledSilence) {
            shell("cp '\(bundledSilence)' '\(silenceBin)'")
        }

        let parakeetBin = buildDir + "/parakeet-transcriber"
        let bundledParakeet = (Bundle.main.resourcePath ?? "") + "/tools/parakeet-transcriber"
        if FileManager.default.fileExists(atPath: bundledParakeet) {
            shell("cp '\(bundledParakeet)' '\(parakeetBin)'")
        }
        await completeStepAsync(.buildDylib)

        // Install framework (overwrite existing binary)
        await setStepAsync(.installFramework)
        let fwDir = moddedApp + "/Contents/Frameworks/SpliceKit.framework"
        shell("cp '\(buildDir)/SpliceKit' '\(fwDir)/Versions/A/SpliceKit'")

        let currentVersion = currentSpliceKitVersion()
        let patcherVersion = currentVersion.isEmpty ? "0.0.0" : currentVersion
        let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
            <key>CFBundleIdentifier</key><string>com.splicekit.SpliceKit</string>
            <key>CFBundleName</key><string>SpliceKit</string>
            <key>CFBundleShortVersionString</key><string>\(patcherVersion)</string>
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
            <key>com.apple.security.app-sandbox</key><false/>
            <key>com.apple.security.cs.disable-library-validation</key><true/>
            <key>com.apple.security.cs.allow-dyld-environment-variables</key><true/>
            <key>com.apple.security.get-task-allow</key><true/>
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

        await setStepAsync(.configureDefaults)
        let cloudContentSnapshot = configureCloudContentDefaults(for: moddedApp)
        await logAsync("CloudContent defaults configured: \(cloudContentSnapshot)")
        await completeStepAsync(.configureDefaults)
        await completeStepAsync(.setupMCP)

        // Post-update diagnostics
        await logAsync("\n--- Post-Update Diagnostics ---")
        let osv = ProcessInfo.processInfo.operatingSystemVersion
        await logAsync("macOS: \(osv.majorVersion).\(osv.minorVersion).\(osv.patchVersion)")
        let fcpInfo = NSDictionary(contentsOfFile: moddedApp + "/Contents/Info.plist")
        await logAsync("FCP: \(fcpInfo?["CFBundleShortVersionString"] ?? "?") (build \(fcpInfo?["CFBundleVersion"] ?? "?"))")
        await logAsync("SpliceKit patcher: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?")")
        await logAsync("Signing identity used: \(signIdentity)")

        let otoolOut = shell("otool -L '\(moddedApp)/Contents/MacOS/Final Cut Pro' 2>&1 | grep -i splice")
        if otoolOut.isEmpty {
            await logAsync("WARNING: SpliceKit load command NOT found in binary")
        } else {
            await logAsync("Load command: \(otoolOut.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        let fwBinary = moddedApp + "/Contents/Frameworks/SpliceKit.framework/Versions/A/SpliceKit"
        if FileManager.default.fileExists(atPath: fwBinary) {
            let attrs = try? FileManager.default.attributesOfItem(atPath: fwBinary)
            let size = (attrs?[.size] as? Int) ?? 0
            await logAsync("Framework binary: exists (\(size) bytes)")
        } else {
            await logAsync("WARNING: Framework binary NOT found")
        }

        let entOut = shell("codesign -d --entitlements - '\(moddedApp)' 2>&1")
        let entKeys = ["app-sandbox", "disable-library-validation", "allow-dyld-environment-variables", "get-task-allow"]
        for key in entKeys {
            await logAsync("Entitlement \(key): \(entOut.contains(key) ? "present" : "MISSING")")
        }

        await logAsync("Log saved to: ~/Library/Logs/SpliceKit/patcher.log")
        await logAsync("--- End Diagnostics ---")

        await setStepAsync(.done)
        await logAsync("\nSpliceKit updated! You can now launch Final Cut Pro.")
    }

    // MARK: - Helpers

    // Shell helpers, bundle reading, and signing identity are in ShellHelpers.swift

    private nonisolated func cloudContentDefaultsDomain(for bundlePath: String) -> String {
        let bundleID = readBundleIdentifier(bundlePath)
        return bundleID.isEmpty ? "com.apple.FinalCut" : bundleID
    }

    private nonisolated func configureCloudContentDefaults(for bundlePath: String) -> String {
        let domain = cloudContentDefaultsDomain(for: bundlePath)
        CFPreferencesSetAppValue("CloudContentFirstLaunchCompleted" as CFString,
                                 kCFBooleanTrue,
                                 domain as CFString)
        CFPreferencesSetAppValue("FFCloudContentDisabled" as CFString,
                                 kCFBooleanTrue,
                                 domain as CFString)
        CFPreferencesAppSynchronize(domain as CFString)
        return cloudContentDefaultsSnapshot(for: domain)
    }

    private nonisolated func cloudContentDefaultsSnapshot(for domain: String) -> String {
        let firstLaunch = preferenceValueString(forKey: "CloudContentFirstLaunchCompleted", domain: domain)
        let disabled = preferenceValueString(forKey: "FFCloudContentDisabled", domain: domain)
        return "\(domain): CloudContentFirstLaunchCompleted=\(firstLaunch) FFCloudContentDisabled=\(disabled)"
    }

    private nonisolated func preferenceValueString(forKey key: String, domain: String) -> String {
        let value = CFPreferencesCopyAppValue(key as CFString, domain as CFString)
        if let bool = value as? Bool {
            return bool ? "true" : "false"
        }
        if let value {
            return String(describing: value)
        }
        return "unset"
    }

    private nonisolated func runtimeLogURL(named name: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/SpliceKit")
            .appendingPathComponent(name)
    }

    private nonisolated func fileModificationDate(at url: URL) -> Date? {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]) else {
            return nil
        }
        return values.contentModificationDate
    }

    private nonisolated func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private nonisolated func tailOfTextFile(_ url: URL, maxCharacters: Int = 1200) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        if text.count <= maxCharacters {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let start = text.index(text.endIndex, offsetBy: -maxCharacters)
        return String(text[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated func latestCrashReportURL(after launchTime: Date) -> URL? {
        let fm = FileManager.default
        let directories = [
            fm.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/DiagnosticReports"),
            URL(fileURLWithPath: "/Library/Logs/DiagnosticReports")
        ]

        var newestReport: (url: URL, modified: Date)?
        for directory in directories {
            guard let urls = try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for url in urls {
                let filename = url.lastPathComponent
                guard filename.hasPrefix("Final Cut Pro"),
                      ["ips", "crash", "txt"].contains(url.pathExtension.lowercased()),
                      let modified = fileModificationDate(at: url),
                      modified >= launchTime.addingTimeInterval(-5) else {
                    continue
                }
                if newestReport == nil || modified > newestReport!.modified {
                    newestReport = (url, modified)
                }
            }
        }
        return newestReport?.url
    }

    private nonisolated func summarizeCrashReport(at url: URL) -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "Unable to read crash report."
        }

        let interestingPrefixes = [
            "Process:",
            "Path:",
            "Identifier:",
            "Version:",
            "Date/Time:",
            "Launch Time:",
            "Exception Type:",
            "Termination Reason:",
            "Triggered by Thread:",
            "Thread ",
            "Binary Images:"
        ]
        let keywords = ["CloudContent", "CloudKit", "ImagePlayground", "SIGTRAP", "SpliceKit"]
        var matches: [String] = []

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if interestingPrefixes.contains(where: { line.hasPrefix($0) }) ||
                keywords.contains(where: { line.localizedCaseInsensitiveContains($0) }) {
                matches.append(line)
            }
            if matches.count >= 20 {
                break
            }
        }

        if matches.isEmpty {
            return String(text.prefix(1200)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return matches.joined(separator: "\n")
    }

    private func launchDiagnostics(launchTime: Date,
                                   spliceKitLogDateBeforeLaunch: Date?) -> [String] {
        var lines: [String] = []
        let logURL = runtimeLogURL(named: "splicekit.log")
        if let modified = fileModificationDate(at: logURL) {
            lines.append("SpliceKit log mtime after launch check: \(iso8601(modified))")
            let freshnessBaseline = spliceKitLogDateBeforeLaunch ?? launchTime
            if modified <= freshnessBaseline {
                lines.append("SpliceKit log did not change after launch. The injected dylib likely never initialized on this run.")
            } else {
                lines.append("SpliceKit log changed after launch. The injected dylib initialized on this run.")
            }
            if let tail = tailOfTextFile(logURL), !tail.isEmpty {
                lines.append("SpliceKit log tail:\n\(tail)")
            }
        } else {
            lines.append("SpliceKit log not found at \(logURL.path)")
        }

        if let crashURL = latestCrashReportURL(after: launchTime) {
            lines.append("Latest Final Cut Pro crash report: \(crashURL.path)")
            lines.append("Crash summary:\n\(summarizeCrashReport(at: crashURL))")
        } else {
            lines.append("No Final Cut Pro crash report newer than the launch time was found.")
        }

        return lines
    }

    private func handleLaunchTermination(process: Process,
                                         launchTime: Date,
                                         spliceKitLogDateBeforeLaunch: Date?) {
        let runtime = Date().timeIntervalSince(launchTime)
        let reason: String
        switch process.terminationReason {
        case .exit:
            reason = "exit"
        case .uncaughtSignal:
            reason = "signal"
        @unknown default:
            reason = "unknown"
        }

        appendLog(String(format: "Final Cut Pro process %d terminated after %.1fs (%@ %d)",
                         process.processIdentifier,
                         runtime,
                         reason,
                         process.terminationStatus))
        if runtime < 90 || process.terminationStatus != 0 || process.terminationReason == .uncaughtSignal {
            for line in launchDiagnostics(
                launchTime: launchTime,
                spliceKitLogDateBeforeLaunch: spliceKitLogDateBeforeLaunch
            ) {
                appendLog(line)
            }
        }
        if launchedFCPProcess?.processIdentifier == process.processIdentifier {
            launchedFCPProcess = nil
            launchMonitorTask?.cancel()
            launchMonitorTask = nil
        }
    }

    private nonisolated func currentSpliceKitVersion() -> String {
        if let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           !shortVersion.isEmpty {
            return shortVersion
        }
        if let buildVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
           !buildVersion.isEmpty {
            return buildVersion
        }
        return ""
    }


    func appendLog(_ text: String) {
        log += text + "\n"
        patcherLogWrite(text)
    }

    private nonisolated func logAsync(_ text: String) async {
        patcherLogWrite(text)
        await MainActor.run { self.log += text + "\n" }
    }

    private nonisolated func setStepAsync(_ step: PatchStep) async {
        await MainActor.run { self.currentStep = step }
    }

    private nonisolated func completeStepAsync(_ step: PatchStep) async {
        await MainActor.run { _ = self.completedSteps.insert(step) }
    }
}
