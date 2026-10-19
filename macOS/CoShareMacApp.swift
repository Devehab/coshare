import SwiftUI
import Combine

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

        // The same panel as a regular window: Dock icon, Spotlight/Launchpad and ⌃⌥C open it,
        // so CoShare is reachable even when a crowded menu bar hides its icon.
        Window("CoShare", id: MainWindow.id) {
            MenuView()
                .environmentObject(engine)
                .environmentObject(engine.history)
                .environmentObject(engine.settings)
                .environmentObject(engine.log)
        }
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var dockSubscription: AnyCancellable?

    /// Clicking the Dock icon (or launching CoShare again from Finder/Spotlight) opens the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainWindow.show()
        return true
    }

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
        GlobalShortcut.register()
        dockSubscription = engine.settings.$showInDock.sink { show in
            NSApp.setActivationPolicy(show ? .regular : .accessory)
        }
        // Opened by hand (not at login right after boot): show the window straight away.
        if ProcessInfo.processInfo.systemUptime > 180 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { MainWindow.show() }
        }

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
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: symbol)
            .onAppear {
                // The menu bar label lives as long as the app: lend its openWindow to AppKit code.
                MainWindow.opener = { openWindow(id: MainWindow.id) }
            }
    }

    private var symbol: String {
        switch engine.pulse {
        case .sent: return "arrow.up.circle.fill"
        case .received: return "arrow.down.circle.fill"
        case .idle:
            switch engine.presence {
            case .online: return "doc.on.clipboard"
            case .paused: return "pause.circle"
            case .quiet: return "moon.zzz"
            }
        }
    }
}

