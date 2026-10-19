import SwiftUI

@main
struct CoShareApp: App {
    @StateObject private var engine = SyncEngine.shared
    @StateObject private var keeper = BackgroundKeeper.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        SyncEngine.shared.start()
        PasteboardSignal.observe()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(engine)
                .environmentObject(engine.history)
                .environmentObject(engine.settings)
                .environmentObject(engine.log)
                .environmentObject(keeper)
                .onValueChange(of: scenePhase) { phase in
                    AppLifecycle.shared.handle(phase)
                }
        }
    }
}

@MainActor
final class AppLifecycle {
    static let shared = AppLifecycle()

    private var suspendedWithoutKeepAlive = false

    func handle(_ phase: ScenePhase) {
        let engine = SyncEngine.shared
        let keeper = BackgroundKeeper.shared
        switch phase {
        case .active:
            keeper.endGracePeriod()
            keeper.applySetting()
            if suspendedWithoutKeepAlive {
                // iOS froze our sockets while we were suspended.
                suspendedWithoutKeepAlive = false
                engine.restartNetwork()
            } else {
                engine.refreshDiscovery()
            }
            Task {
                // A copy made on this phone while away wins; otherwise fetch what the others copied.
                if !engine.pollNow() {
                    await engine.pullLatest()
                }
            }
        case .background:
            if !keeper.isRunning {
                suspendedWithoutKeepAlive = true
                keeper.beginGracePeriod()
            }
        default:
            break
        }
    }
}

/// The system posts this Darwin notification whenever the general pasteboard changes,
/// which wakes the poll immediately instead of waiting for the next timer tick.
enum PasteboardSignal {
    static func observe() {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), nil,
            { _, _, _, _, _ in
                Task { @MainActor in SyncEngine.shared.pollNow(force: true) }
            },
            "com.apple.pasteboard.notify.changed" as CFString, nil, .deliverImmediately
        )
    }
}
