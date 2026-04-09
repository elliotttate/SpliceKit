// SpliceKitPatcher -- GUI patcher app for SpliceKit.
//
// Single-file SwiftUI app that copies FCP, compiles the SpliceKit dylib,
// injects it via LC_LOAD_DYLIB, and re-signs with a local identity when
// available or ad-hoc as a fallback. The result is a standalone modded FCP
// that loads SpliceKit on launch.

import SwiftUI
import AppKit
import Sparkle

// MARK: - Patcher Logic

enum InstallState: Equatable {
    case notInstalled       // No modded FCP found
    case current            // Installed, framework matches patcher's build
    case updateAvailable    // SpliceKit framework differs from patcher's build
    case fcpUpdateAvailable // Stock FCP version changed since modded copy was made
    case unknown
}

/// Each step in the patching pipeline, shown as a checklist in the UI.
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
        destDir = NSHomeDirectory() + "/Applications/SpliceKit"
        // Find SpliceKit sources. Priority:
        // 1. Embedded in app bundle (Resources/Sources/) — self-contained release
        // 2. Relative to app bundle (developer running from repo checkout)
        // 3. Common local paths
        // 4. Cache dir (will download into it during patch)
        var found = ""

        // 1. Embedded in app bundle
        if let resourcePath = Bundle.main.resourcePath {
            let embedded = resourcePath + "/Sources"
            if FileManager.default.fileExists(atPath: embedded + "/SpliceKit.m") {
                found = resourcePath
            }
        }

        // 2. Relative to app bundle (developer workflow)
        if found.isEmpty {
            var dir = (Bundle.main.bundlePath as NSString).deletingLastPathComponent
            for _ in 0..<5 {
                if FileManager.default.fileExists(atPath: dir + "/Sources/SpliceKit.m") {
                    found = dir; break
                }
                dir = (dir as NSString).deletingLastPathComponent
            }
        }

        // 3. No hardcoded user paths — skip to cache dir

        // 4. Cache dir (download during patch)
        if found.isEmpty {
            found = NSHomeDirectory() + "/Library/Caches/SpliceKit"
        }
        repoDir = found
        // Defer status check — shell() pumps the run loop via waitUntilExit,
        // which crashes if called during SwiftUI view graph initialization.
        DispatchQueue.main.async { [self] in
            checkStatus()
        }
    }

    /// Evaluate install state: is SpliceKit injected? Is it the current build? Is FCP up to date?
    func checkStatus() {
        let binary = moddedApp + "/Contents/MacOS/Final Cut Pro"
        let installedDylib = moddedApp + "/Contents/Frameworks/SpliceKit.framework/Versions/A/SpliceKit"
        let installedPlist = moddedApp + "/Contents/Frameworks/SpliceKit.framework/Versions/A/Resources/Info.plist"

        // Read stock FCP version (also shown on the not-installed card)
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
        // Try binary hash first (bundled dylib), then fall back to version comparison
        let bundledDylib = (Bundle.main.resourcePath ?? "") + "/SpliceKit"
        if FileManager.default.fileExists(atPath: bundledDylib),
           FileManager.default.fileExists(atPath: installedDylib) {
            let bundledHash = fileHash(bundledDylib)
            let installedHash = fileHash(installedDylib)
            if !bundledHash.isEmpty && !installedHash.isEmpty && bundledHash != installedHash {
                status = .updateAvailable
                return
            }
        } else if FileManager.default.fileExists(atPath: installedPlist) {
            // Fall back to version comparison for dev builds without bundled binary
            let patcherVer = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
            let installedVer = shell("/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' '\(installedPlist)' 2>/dev/null")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !patcherVer.isEmpty && !installedVer.isEmpty && !installedVer.contains("Doesn't Exist") && patcherVer != installedVer {
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
        shell("pkill -f SpliceKit 2>/dev/null; sleep 1")
        do {
            try FileManager.default.removeItem(atPath: destDir)
            appendLog("Removed \(destDir)")
            status = .notInstalled
            bridgeConnected = false
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

        // Step 3: Compile universal (arm64+x86_64) dylib; -undefined dynamic_lookup
        // because FCP symbols are only available at runtime via dyld.
        await setStepAsync(.buildDylib)
        await logAsync("Compiling SpliceKit dylib...")
        let buildDir = NSTemporaryDirectory() + "SpliceKit_build"
        shell("mkdir -p '\(buildDir)'")
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

        // Build parakeet-transcriber tool (Swift Package with FluidAudio dependency)
        let parakeetSrcDir = repoDir + "/patcher/SpliceKitPatcher.app/Contents/Resources/tools/parakeet-transcriber"
        let parakeetBin = buildDir + "/parakeet-transcriber"
        if FileManager.default.fileExists(atPath: parakeetSrcDir + "/Package.swift") {
            await logAsync("Building Parakeet transcriber (may take a moment on first run)...")
            // Always stage the package in a persistent cache location so the runtime
            // can rebuild it later if the deployed binary is missing.
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

        // Deploy tools to ~/Applications/SpliceKit/tools/
        let toolsDir = destDir + "/tools"
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

        // Step 5: Patch the Mach-O binary so dyld loads SpliceKit on launch
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

        // Sign only the components we modified (SpliceKit framework and the main
        // app binary).  Apple's own frameworks must keep their original signatures
        // or internal integrity checks (e.g. ProAppSupport +[PCApp isiMovie])
        // will abort on launch. We only re-sign the wrapper and SpliceKit.
        var signIdentity = preferredSigningIdentity() ?? "-"
        if signIdentity == "-" {
            await logAsync("No local codesigning identity found; using ad-hoc signature (higher risk of macOS launch/security blocks)")
        } else {
            await logAsync("Using signing identity: \(signIdentity)")
        }

        await logAsync("Signing SpliceKit framework and app bundle...")
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

        // Only sign the SpliceKit framework (ours) and the main app bundle.
        // Leave all Apple frameworks, plugins, and helpers with their original
        // Apple signatures intact.
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
            // With mixed signatures (Apple + ad-hoc) the top-level verify may
            // report issues, but the app can still launch if library validation
            // is disabled via entitlements.  Log instead of failing.
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
        await logAsync("\nPatching complete! You can now launch the modded FCP.")
    }

    /// Update path: rebuild framework + tools, re-sign. Skips FCP copy and dylib injection.
    private nonisolated func runUpdate() async throws {
        let repoDir = await MainActor.run { self.repoDir }
        let moddedApp = await MainActor.run { self.moddedApp }
        let destDir = await MainActor.run { self.destDir }

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

        // Build tools
        let silenceSwift = repoDir + "/tools/silence-detector.swift"
        let silenceBin = buildDir + "/silence-detector"
        if FileManager.default.fileExists(atPath: silenceSwift) {
            _ = shell("swiftc -O -suppress-warnings -o '\(silenceBin)' '\(silenceSwift)' 2>&1")
        } else {
            let prebuilt = repoDir + "/tools/silence-detector"
            if FileManager.default.fileExists(atPath: prebuilt) {
                shell("cp '\(prebuilt)' '\(silenceBin)'")
            }
        }

        let parakeetSrcDir = repoDir + "/patcher/SpliceKitPatcher.app/Contents/Resources/tools/parakeet-transcriber"
        let parakeetBin = buildDir + "/parakeet-transcriber"
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
        let toolsDir = destDir + "/tools"
        shell("mkdir -p '\(toolsDir)'")
        if FileManager.default.fileExists(atPath: silenceBin) {
            shell("cp '\(silenceBin)' '\(toolsDir)/silence-detector'")
        }
        if FileManager.default.fileExists(atPath: parakeetBin) {
            shell("cp '\(parakeetBin)' '\(toolsDir)/parakeet-transcriber'")
            shell("cp '\(parakeetBin)' '\(fwDir)/Versions/A/Resources/parakeet-transcriber'")
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
                Text("SpliceKit Patcher")
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
                if model.status != .notInstalled && model.status != .unknown {
                    Circle()
                        .fill(model.bridgeConnected ? .green : .orange)
                        .frame(width: 10, height: 10)
                    Text(model.bridgeConnected ? "Connected" : "Not Running")
                        .font(.caption)
                        .foregroundStyle(model.bridgeConnected ? .green : .orange)
                }
            }

            if model.hasBothEditions {
                HStack(spacing: 6) {
                    Text("Edition:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("", selection: Binding(
                        get: { model.sourceApp },
                        set: { model.switchEdition(to: $0) }
                    )) {
                        ForEach(model.availableEditions, id: \.path) { edition in
                            Text(edition.label).tag(edition.path)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                }
            }

            if model.status == .fcpUpdateAvailable && !model.stockFcpVersion.isEmpty {
                Label("Modded copy v\(model.fcpVersion) \u{2192} Stock v\(model.stockFcpVersion)", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if !model.fcpVersion.isEmpty {
                Label("\((model.sourceApp as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")) v\(model.fcpVersion)", systemImage: "info.circle")
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
            case .current:
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .font(.title)
            case .updateAvailable:
                Image(systemName: "arrow.up.circle.fill")
                    .foregroundStyle(.blue)
                    .font(.title)
            case .fcpUpdateAvailable:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.title)
            case .notInstalled:
                Image(systemName: "wrench.and.screwdriver")
                    .foregroundStyle(.orange)
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
        case .current: return "SpliceKit Installed"
        case .updateAvailable: return "SpliceKit Update Available"
        case .fcpUpdateAvailable: return "Final Cut Pro Updated"
        case .notInstalled: return "Not Patched"
        case .unknown: return "Checking..."
        }
    }

    var statusSubtitle: String {
        switch model.status {
        case .current: return model.moddedApp
        case .updateAvailable: return "A newer version of SpliceKit is ready to install."
        case .fcpUpdateAvailable: return "Final Cut Pro has been updated. Rebuild the modded copy."
        case .notInstalled: return "Ready to patch Final Cut Pro"
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
            if model.status != .notInstalled && model.status != .unknown {
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

                if model.status == .updateAvailable {
                    Button {
                        model.launch()
                    } label: {
                        Label("Launch FCP", systemImage: "play.fill")
                    }
                    .disabled(model.isPatching)

                    Button {
                        model.updateSpliceKit()
                    } label: {
                        Label("Update SpliceKit", systemImage: "arrow.up.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isPatching)
                } else if model.status == .fcpUpdateAvailable {
                    Button {
                        model.launch()
                    } label: {
                        Label("Launch FCP", systemImage: "play.fill")
                    }
                    .disabled(model.isPatching)

                    Button {
                        model.rebuildModdedApp()
                    } label: {
                        Label("Rebuild", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isPatching)
                } else {
                    Button {
                        model.launch()
                    } label: {
                        Label("Launch FCP", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isPatching)
                }
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

// MARK: - Sparkle Auto-Update (via appcast feed)

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
struct SpliceKitPatcherApp: App {
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
