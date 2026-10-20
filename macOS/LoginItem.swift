import Foundation
import ServiceManagement

/// Open at login: SMAppService on macOS 13+, a per-user LaunchAgent on macOS 12.
enum LoginItem {
    static var isEnabled: Bool {
        if #available(macOS 13.0, *) { return SMAppService.mainApp.status == .enabled }
        return FileManager.default.fileExists(atPath: legacyAgentURL.path)
    }

    static func setEnabled(_ enabled: Bool) throws {
        if #available(macOS 13.0, *) {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return
        }
        if enabled {
            let agent: [String: Any] = [
                "Label": legacyLabel,
                "ProgramArguments": ["/usr/bin/open", "-a", Bundle.main.bundlePath],
                "RunAtLoad": true,
                "ProcessType": "Interactive",
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: agent, format: .xml, options: 0)
            try FileManager.default.createDirectory(at: legacyAgentURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: legacyAgentURL, options: .atomic)
        } else if FileManager.default.fileExists(atPath: legacyAgentURL.path) {
            try FileManager.default.removeItem(at: legacyAgentURL)
        }
    }

    private static let legacyLabel = "com.ehabk.CoShare.mac.login"
    private static var legacyAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(legacyLabel).plist")
    }

    /// The whole point is to always be running, so opt in to launch-at-login once.
    @MainActor
    static func enableOnFirstLaunch(log: ActivityLog) {
        let environment = AppEnvironment.current
        guard environment.profile == nil, !environment.defaults.bool(forKey: "loginItemConfigured") else { return }
        environment.defaults.set(true, forKey: "loginItemConfigured")
        do {
            try setEnabled(true)
            log.add("تم تفعيل التشغيل التلقائي عند بدء الجهاز")
        } catch {
            log.add("تعذّر تفعيل التشغيل التلقائي: \(error.localizedDescription)", isError: true)
        }
    }
}
