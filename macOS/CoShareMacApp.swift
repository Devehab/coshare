import SwiftUI
import Combine

/// macOS 13 and later get the SwiftUI menu-bar extra and window; macOS 12 gets the same panel and
/// window from an AppKit status item (MenuBarExtra and Window don't exist there).
@main
enum CoShareLauncher {
    @MainActor
    static func main() {
        // COSHARE_LEGACY_SHELL=1 tries the macOS 12 shell on a newer Mac (testing).
        let forceLegacy = ProcessInfo.processInfo.environment["COSHARE_LEGACY_SHELL"] != nil
        if #available(macOS 13.0, *), !forceLegacy {
            CoShareMacApp.main()
        } else {
            LegacyStatusApp.main()
        }
    }
}

@available(macOS 13.0, *)
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
                .tint(.signal)
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
                .tint(.signal)
        }
        .windowResizability(.contentSize)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var dockSubscription: AnyCancellable?

    /// Clicking the Dock icon (or launching CoShare again from Finder/Spotlight) opens the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainWindow.show()
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Two copies would share one device ID and clipboard and step on each other.
        // The copy launched last wins (e.g. a fresh build run from Xcode).
        // A test copy with its own COSHARE_PROFILE has its own device ID and data, so it leaves the real one alone.
        let isTestCopy = ProcessInfo.processInfo.environment["COSHARE_PROFILE"] != nil
        if !isTestCopy, let bundleID = Bundle.main.bundleIdentifier {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { $0 != NSRunningApplication.current }
                .forEach { $0.terminate() }
        }
        let engine = SyncEngine.shared
        engine.start()
        if DevSnapshots.isRequested {
            Task { await DevSnapshots.run() }
            return
        }
        if isTestCopy { return }
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

/// The menu-bar icon: a short arrow when a clip goes out or comes in, otherwise the connection state.
enum StatusIcon {
    static func symbol(pulse: SyncEngine.Pulse, presence: NetworkPresence) -> String {
        switch pulse {
        case .sent: return "arrow.up.circle.fill"
        case .received: return "arrow.down.circle.fill"
        case .idle:
            switch presence {
            case .online: return "doc.on.clipboard"
            case .paused: return "pause.circle"
            case .quiet: return "moon.zzz"
            }
        }
    }
}

@available(macOS 13.0, *)
struct MenuBarLabel: View {
    @ObservedObject var engine: SyncEngine
    @ObservedObject var settings: AppSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: StatusIcon.symbol(pulse: engine.pulse, presence: engine.presence))
            .onAppear {
                // The menu bar label lives as long as the app: lend its openWindow to AppKit code.
                MainWindow.opener = { openWindow(id: MainWindow.id) }
            }
    }
}

// MARK: - macOS 12

/// The same CoShare panel in a status-item popover, and the same window, built with AppKit.
@MainActor
enum LegacyStatusApp {
    /// NSApplication only keeps a weak reference to its delegate.
    private static let delegate = LegacyAppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.run()
    }
}

final class LegacyAppDelegate: AppDelegate {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var window: NSWindow?
    private var iconSubscription: AnyCancellable?

    override func applicationDidFinishLaunching(_ notification: Notification) {
        MainWindow.opener = { [weak self] in self?.showWindow() }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        statusItem = item
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: Self.panel())
        let engine = SyncEngine.shared
        iconSubscription = engine.$pulse.combineLatest(engine.$presence)
            .receive(on: RunLoop.main)
            .sink { [weak self] pulse, presence in
                let image = NSImage(systemSymbolName: StatusIcon.symbol(pulse: pulse, presence: presence),
                                    accessibilityDescription: "CoShare")
                image?.isTemplate = true
                self?.statusItem?.button?.image = image
            }
        super.applicationDidFinishLaunching(notification)
    }

    @MainActor
    private static func panel() -> some View {
        let engine = SyncEngine.shared
        return MenuView()
            .environmentObject(engine)
            .environmentObject(engine.history)
            .environmentObject(engine.settings)
            .environmentObject(engine.log)
            .tint(.signal)
    }

    @MainActor @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    @MainActor private func showWindow() {
        if window == nil {
            let newWindow = NSWindow(contentViewController: NSHostingController(rootView: Self.panel()))
            newWindow.title = "CoShare"
            newWindow.styleMask = [.titled, .closable, .miniaturizable]
            newWindow.isReleasedWhenClosed = false
            newWindow.center()
            window = newWindow
        }
        window?.makeKeyAndOrderFront(nil)
    }
}
