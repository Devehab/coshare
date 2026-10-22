import Foundation
import UserNotifications

/// Shows "device in / device out" notifications (iPhone, iPad and Mac). Each device has one slot,
/// so "out" replaces its earlier "in" instead of piling up.
@MainActor
final class PresenceNotifier: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = PresenceNotifier()

    /// Whether the system lets CoShare show notifications (nil until known).
    @Published private(set) var status: UNAuthorizationStatus?

    /// Only a real app bundle has a notification center (not the TestPeer tool or UI snapshots).
    private let isAvailable = Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
        && ProcessInfo.processInfo.environment["COSHARE_SNAPSHOT_DIR"] == nil

    private override init() {
        super.init()
        guard isAvailable else { return }
        UNUserNotificationCenter.current().delegate = self
        refreshStatus()
    }

    /// Asks once for permission when device notifications are on; afterwards only reads the answer.
    func prepare(enabled: Bool) {
        guard isAvailable, enabled else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else {
                Task { @MainActor in self.status = settings.authorizationStatus }
                return
            }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
                Task { @MainActor in self.refreshStatus() }
            }
        }
    }

    func refreshStatus() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            Task { @MainActor in self.status = settings.authorizationStatus }
        }
    }

    /// Shows it; `failed` hears why if the system refused.
    func post(_ event: PresenceWatch.Event, use24Hour: Bool, failed: @escaping @MainActor (String) -> Void) {
        let content = UNMutableNotificationContent()
        let (title, body) = Self.text(for: event, use24Hour: use24Hour)
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = "presence"
        guard isAvailable else { return }
        let request = UNNotificationRequest(identifier: "presence.\(event.member.id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            guard let error else { return }
            Task { @MainActor in failed(error.localizedDescription) }
        }
    }

    /// Title and body in the apps' own words (also used by the tests).
    nonisolated static func text(for event: PresenceWatch.Event, use24Hour: Bool) -> (String, String) {
        let name = event.member.name
        let groups = event.member.groups.map { "«\($0.name)»" }.joined(separator: " و")
        let inGroups = event.member.groups.count > 1 ? "بمجموعات \(groups)" : "بمجموعة \(groups)"
        switch event.kind {
        case .joined:
            return ("جهاز جديد انضم: \(name)", "صار \(inGroups)")
        case .back:
            return ("\(name) رجع متصل", inGroups)
        case .left(let reason):
            let why: String
            switch reason {
            case .quiet(let until): why = "دخل وقت الإيقاف لحد \(Format.clock(until, h24: use24Hour))"
            case .paused: why = "وقّف المشاركة"
            case .lost: why = "انقطع: طلع من الشبكة، أو نام، أو انسكّر CoShare عليه"
            }
            return ("\(name) طلع", "\(why) · \(inGroups)")
        }
    }

    // Show the banner even while CoShare is the app in front.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}
