import SwiftUI
import Carbon.HIToolbox

/// Opens the CoShare window from AppKit code (Dock click, global shortcut).
@MainActor
enum MainWindow {
    static let id = "main"
    static var opener: (() -> Void)?

    static func show() {
        NSApp.activate(ignoringOtherApps: true)
        opener?()
    }
}

/// ⌃⌥C anywhere opens CoShare (Carbon hot keys need no Accessibility permission).
enum GlobalShortcut {
    /// In a left-to-right isolate so it doesn't read "C⌥⌃" inside Arabic text.
    static let display = "\u{2066}⌃⌥C\u{2069}"
    private static var reference: EventHotKeyRef?

    static func register() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { MainWindow.show() }
            return noErr
        }, 1, &spec, nil, nil)
        let hotKeyID = EventHotKeyID(signature: OSType(0x4353_484B), id: 1) // "CSHK"
        RegisterEventHotKey(UInt32(kVK_ANSI_C), UInt32(controlKey | optionKey), hotKeyID,
                            GetApplicationEventTarget(), 0, &reference)
    }
}

/// Development aid: with a COSHARE_PROFILE (never the real data), COSHARE_SNAPSHOT_DIR=<dir> draws the
/// window's screens to PNG files and quits. COSHARE_SNAPSHOT_INVITE=coshare://join?… joins a group first.
@MainActor
enum DevSnapshots {
    static var isRequested: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["COSHARE_SNAPSHOT_DIR"] != nil && env["COSHARE_PROFILE"] != nil
    }

    static func run() async {
        let env = ProcessInfo.processInfo.environment
        let dir = URL(fileURLWithPath: env["COSHARE_SNAPSHOT_DIR"] ?? ".")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let engine = SyncEngine.shared
        if let invite = env["COSHARE_SNAPSHOT_INVITE"].flatMap(URL.init(string:)).flatMap(GroupInvite.parse),
           !engine.settings.groups.contains(where: { $0.id == invite.id }) {
            engine.join(invite: invite)
        }
        try? await Task.sleep(nanoseconds: UInt64((Double(env["COSHARE_SNAPSHOT_WAIT"] ?? "") ?? 6) * 1e9))
        let groupID = engine.settings.groups.first?.id ?? ""
        let shots: [(String, MenuView.Tab, GroupsRoute?, Bool)] = [
            ("groups", .devices, nil, false),
            ("join", .devices, .join, false),
            ("create", .devices, .create, false),
            ("group", .devices, .group(groupID), false),
            ("group-invite", .devices, .group(groupID), true),
            ("history", .history, nil, false),
            ("log", .log, nil, false),
            ("settings", .settings, nil, false),
        ]
        for dark in [false, true] {
            for (name, tab, route, invite) in shots {
                let view = MenuView(tab: tab, route: route, inviteFor: invite ? groupID : nil, height: 900)
                    .environmentObject(engine)
                    .environmentObject(engine.history)
                    .environmentObject(engine.settings)
                    .environmentObject(engine.log)
                let host = NSHostingView(rootView: view)
                host.frame = NSRect(x: 0, y: 0, width: 380, height: 900)
                let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 380, height: 900),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = host
                window.orderFront(nil)
                try? await Task.sleep(nanoseconds: 900_000_000)
                host.layoutSubtreeIfNeeded()
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?
                        .write(to: dir.appendingPathComponent("\(name)\(dark ? "-dark" : "").png"))
                }
                window.orderOut(nil)
            }
        }
        NSApp.terminate(nil)
    }
}
