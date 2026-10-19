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
    static let display = "⌃⌥C"
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
