import Foundation
import ServiceManagement

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
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
