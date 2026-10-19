import SwiftUI

@main
struct CoShareMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var engine = SyncEngine.shared

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(engine)
                .environmentObject(engine.history)
                .environmentObject(engine.settings)
                .environmentObject(engine.log)
        } label: {
            MenuBarLabel(engine: engine, settings: engine.settings)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Two copies would share one device ID and clipboard and step on each other.
        // The copy launched last wins (e.g. a fresh build run from Xcode).
        if let bundleID = Bundle.main.bundleIdentifier {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { $0 != NSRunningApplication.current }
                .forEach { $0.terminate() }
        }
        let engine = SyncEngine.shared
        engine.start()
        LoginItem.enableOnFirstLaunch(log: engine.log)

        // Sockets and Bonjour registrations go stale while the Mac sleeps.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                SyncEngine.shared.log.add("استيقظ الجهاز — إعادة الاتصال")
                SyncEngine.shared.restartNetwork()
            }
        }
    }
}

struct MenuBarLabel: View {
    @ObservedObject var engine: SyncEngine
    @ObservedObject var settings: AppSettings

    var body: some View {
        Image(systemName: symbol)
    }

    private var symbol: String {
        switch engine.pulse {
        case .sent: return "arrow.up.circle.fill"
        case .received: return "arrow.down.circle.fill"
        case .idle: return settings.paused ? "pause.circle" : "doc.on.clipboard"
        }
    }
}

