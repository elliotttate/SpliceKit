import Foundation

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
