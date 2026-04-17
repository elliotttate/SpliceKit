import Foundation
import Sentry

enum PatcherSentry {
    nonisolated(unsafe) private static var started = false
    nonisolated(unsafe) private static var enabled = false
    nonisolated(unsafe) private static var previousRunSummary: [String: Any]?

    private static func scrub(_ value: String) -> String {
        value.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private static func scrub(_ value: Any) -> Any {
        switch value {
        case let string as String:
            return scrub(string)
        case let array as [Any]:
            return array.map(scrub)
        case let dict as [String: Any]:
            return dict.mapValues(scrub)
        default:
            return value
        }
    }

    private static func config() -> [String: Any]? {
        guard let url = Bundle.main.url(forResource: "SpliceKitSentryConfig", withExtension: "plist"),
              let raw = NSDictionary(contentsOf: url) as? [String: Any] else {
            return nil
        }
        return raw
    }

    private static func runtimeLogTail(named name: String, maxCharacters: Int = 3000) -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/SpliceKit")
            .appendingPathComponent(name)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count <= maxCharacters {
            return scrub(trimmed)
        }
        let start = trimmed.index(trimmed.endIndex, offsetBy: -maxCharacters)
        return scrub(String(trimmed[start...]))
    }

    private static func sanitize(_ event: Event) -> Event? {
        event.user = nil
        if let message = event.message?.message {
            event.message?.message = scrub(message)
        }
        if let logger = event.logger {
            event.logger = scrub(logger)
        }
        if let extra = event.extra {
            event.extra = scrub(extra) as? [String: Any]
        }
        if let breadcrumbs = event.breadcrumbs {
            event.breadcrumbs = breadcrumbs.map { crumb in
                crumb.message = crumb.message.map(scrub)
                if let data = crumb.data {
                    crumb.data = scrub(data) as? [String: Any]
                }
                return crumb
            }
        }
        return event
    }

    static func start() {
        guard !started else { return }
        started = true

        guard let config = config(),
              let dsn = config["PatcherDSN"] as? String,
              !dsn.isEmpty else {
            return
        }

        let environment = (config["Environment"] as? String) ?? "production"
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
        let releaseName = (config["ReleaseName"] as? String) ?? "splicekit@\(version)"

        SentrySDK.start { options in
            options.dsn = dsn
            options.environment = environment
            options.releaseName = releaseName
            options.dist = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String)
                ?? (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
            options.sendDefaultPii = false
            options.enableAutoSessionTracking = false
            options.enableNetworkBreadcrumbs = false
            options.enableNetworkTracking = false
            options.enableCaptureFailedRequests = false
            options.enableAppHangTracking = false
            options.enableMetricKit = false
            options.tracesSampleRate = 0
            options.maxBreadcrumbs = 150
            options.beforeSend = sanitize
            options.onLastRunStatusDetermined = { status, crashEvent in
                guard status == .didCrash else { return }
                var summary: [String: Any] = [:]
                if let message = crashEvent?.message?.message, !message.isEmpty {
                    summary["message"] = scrub(message)
                }
                if let reason = crashEvent?.exceptions?.first?.value(forKey: "value") as? String, !reason.isEmpty {
                    summary["reason"] = scrub(reason)
                }
                previousRunSummary = summary
            }
        }

        enabled = SentrySDK.isEnabled
        guard enabled else { return }

        SentrySDK.configureScope { scope in
            scope.setTag(value: "patcher", key: "component")
            scope.setTag(value: "true", key: "splicekit_patcher")
            scope.setTag(value: Bundle.main.bundleIdentifier ?? "com.splicekit.app", key: "bundle_id")
            if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                scope.setTag(value: version, key: "splicekit_version")
            }
            scope.setTag(value: environment, key: "environment")
        }

        if let summary = previousRunSummary {
            captureMessage(
                "SpliceKit patcher detected a crash on the previous run",
                level: .error,
                context: "patcher.last_run_crash",
                extras: [
                    "previous_log_tail": runtimeLogTail(named: "patcher.previous.log") ?? "",
                    "summary": summary
                ]
            )
        }
    }

    static func addBreadcrumb(_ message: String,
                              category: String = "patcher.log",
                              level: SentryLevel = .info,
                              data: [String: Any] = [:]) {
        guard enabled, !message.isEmpty else { return }
        let crumb = Breadcrumb(level: level, category: category)
        crumb.type = "default"
        crumb.origin = "splicekit.patcher"
        crumb.message = scrub(message)
        if !data.isEmpty {
            crumb.data = scrub(data) as? [String: Any]
        }
        SentrySDK.addBreadcrumb(crumb)
    }

    static func capture(error: Error, context: String, extras: [String: Any] = [:]) {
        guard enabled else { return }
        SentrySDK.capture(error: error) { scope in
            scope.setTag(value: "patcher", key: "component")
            scope.setTag(value: scrub(context), key: "patcher_context")
            if !extras.isEmpty {
                scope.setContext(value: scrub(extras) as? [String: Any] ?? [:], key: "patcher")
            }
            scope.setLevel(.error)
        }
    }

    static func captureMessage(_ message: String,
                               level: SentryLevel = .warning,
                               context: String,
                               extras: [String: Any] = [:]) {
        guard enabled, !message.isEmpty else { return }
        SentrySDK.capture(message: scrub(message)) { scope in
            scope.setTag(value: "patcher", key: "component")
            scope.setTag(value: scrub(context), key: "patcher_context")
            if !extras.isEmpty {
                scope.setContext(value: scrub(extras) as? [String: Any] ?? [:], key: "patcher")
            }
            scope.setLevel(level)
        }
    }
}
