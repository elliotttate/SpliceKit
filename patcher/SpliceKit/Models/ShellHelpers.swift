import Foundation
import CoreFoundation

/// Run a shell command synchronously, returning output and exit status.
func shellResult(_ command: String) -> (output: String, status: Int32) {
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

/// Run a shell command synchronously, returning output.
@discardableResult
func shell(_ command: String) -> String {
    shellResult(command).output
}

/// Single-quote a string for safe shell interpolation.
func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Read Photos access from signed entitlement XML, requiring a Boolean true value.
func photosLibraryEntitlementEnabled(in xml: String) -> Bool {
    guard let data = xml.data(using: .utf8),
          let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
          let entitlements = plist as? [String: Any],
          let value = entitlements["com.apple.security.personal-information.photos-library"] as? NSNumber,
          CFGetTypeID(value) == CFBooleanGetTypeID() else {
        return false
    }
    return value.boolValue
}

private func normalizeExecutablePath(_ path: String) -> String {
    let expanded = (path as NSString).expandingTildeInPath
    return (expanded as NSString).standardizingPath
}

private func runCapturedProcess(executablePath: String, arguments: [String]) -> (output: String, status: Int32)? {
    let process = Process()
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    process.executableURL = URL(fileURLWithPath: executablePath)
    process.arguments = arguments
    do {
        try process.run()
    } catch {
        return nil
    }
    process.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return (String(data: data, encoding: .utf8) ?? "", process.terminationStatus)
}

private func firstExecutablePath(in output: String) -> String? {
    let fm = FileManager.default
    for rawLine in output.split(whereSeparator: \.isNewline) {
        let candidate = normalizeExecutablePath(String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines))
        if !candidate.isEmpty && fm.isExecutableFile(atPath: candidate) {
            return candidate
        }
    }
    return nil
}

func resolveExecutable(named executableName: String) -> String? {
    let trimmedName = executableName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty else { return nil }

    let fm = FileManager.default
    let home = NSHomeDirectory()
    let overrideEnvName = "SPLICEKIT_" + trimmedName
        .uppercased()
        .replacingOccurrences(of: "-", with: "_") + "_PATH"

    var seen = Set<String>()
    var candidates: [String] = []
    func addCandidate(_ path: String?) {
        guard let path else { return }
        let normalized = normalizeExecutablePath(path)
        guard !normalized.isEmpty else { return }
        if seen.insert(normalized).inserted {
            candidates.append(normalized)
        }
    }

    addCandidate(ProcessInfo.processInfo.environment[overrideEnvName])
    if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
        for directory in pathEnv.split(separator: ":") where !directory.isEmpty {
            addCandidate(String(directory) + "/\(trimmedName)")
        }
    }

    [
        home + "/Applications/SpliceKit/tools/\(trimmedName)",
        home + "/.local/bin/\(trimmedName)",
        home + "/.pyenv/shims/\(trimmedName)",
        home + "/.asdf/shims/\(trimmedName)",
        home + "/.nix-profile/bin/\(trimmedName)",
        "/nix/var/nix/profiles/default/bin/\(trimmedName)",
        "/opt/homebrew/bin/\(trimmedName)",
        "/usr/local/bin/\(trimmedName)",
        "/opt/local/bin/\(trimmedName)",
        "/usr/bin/\(trimmedName)"
    ].forEach(addCandidate)

    for candidate in candidates where fm.isExecutableFile(atPath: candidate) {
        return candidate
    }

    let shellCommand = "command -v \(shellQuote(trimmedName)) 2>/dev/null || which \(shellQuote(trimmedName)) 2>/dev/null"
    var shells: [String] = []
    func addShell(_ path: String?) {
        guard let path else { return }
        let normalized = normalizeExecutablePath(path)
        guard !normalized.isEmpty, !shells.contains(normalized), fm.isExecutableFile(atPath: normalized) else {
            return
        }
        shells.append(normalized)
    }

    addShell(ProcessInfo.processInfo.environment["SHELL"])
    addShell("/bin/zsh")
    addShell("/bin/bash")
    addShell("/bin/sh")

    for shellPath in shells {
        guard let result = runCapturedProcess(executablePath: shellPath, arguments: ["-lc", shellCommand]),
              result.status == 0,
              let resolved = firstExecutablePath(in: result.output) else {
            continue
        }
        return resolved
    }

    return nil
}

/// Find the best available codesigning identity on this machine.
/// Prefers Apple Development, then Developer ID Application, then any available.
func preferredSigningIdentity() -> String? {
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

/// Read a value from an Info.plist inside an app or framework bundle.
/// Searches common plist locations (Contents/Info.plist, Versions/A/Resources/Info.plist, etc.)
func readBundleValue(_ key: String, bundlePath: String) -> String {
    let fm = FileManager.default
    let plistCandidates = [
        bundlePath + "/Contents/Info.plist",
        bundlePath + "/Versions/A/Resources/Info.plist",
        bundlePath + "/Resources/Info.plist"
    ]

    for plistPath in plistCandidates where fm.fileExists(atPath: plistPath) {
        let quotedPath = shellQuote(plistPath)
        let value = shell("/usr/libexec/PlistBuddy -c 'Print :\(key)' \(quotedPath) 2>/dev/null")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty && !value.contains("Doesn't Exist") {
            return value
        }
    }

    return ""
}

/// Read a bundle version from either CFBundleShortVersionString or CFBundleVersion.
func readBundleVersion(_ bundlePath: String) -> String {
    for key in ["CFBundleShortVersionString", "CFBundleVersion"] {
        let value = readBundleValue(key, bundlePath: bundlePath)
        if !value.isEmpty {
            return value
        }
    }
    return ""
}

/// Read the CFBundleIdentifier from a bundle.
func readBundleIdentifier(_ bundlePath: String) -> String {
    readBundleValue("CFBundleIdentifier", bundlePath: bundlePath)
}
