// Renders the macOS menu bar window with sample data to PNGs, for checking the layout
// without clicking through the real menu. Output: build/snapshots/*.png
import AppKit
import SwiftUI

@MainActor
func renderSnapshots(into directory: URL) {
    let engine = SyncEngine.shared
    engine.history.clear()
    engine.log.clear()
    let imageURL = URL(fileURLWithPath: "macOS/Assets.xcassets/AppIcon.appiconset/icon_256@2x.png")
    if let data = try? Data(contentsOf: imageURL) {
        let image = ClipContent.image(data, uti: "public.png")
        engine.history.add(image, hash: image.hash, deviceName: engine.settings.deviceName, direction: .sent,
                           date: Date().addingTimeInterval(-3600))
    }
    let samples: [(String, String, ClipDirection, TimeInterval)] = [
        ("https://github.com/apple/swift/pull/71234", "MacBook المكتب", .received, -1500),
        ("اجتماع الفريق الساعة ٤ عصراً في غرفة الاجتماعات الكبيرة، لا تنسَ إحضار التقرير", "MacBook المكتب", .sent, -600),
        ("Your verification code is 482913", "iPhone إيهاب", .received, -5),
    ]
    for (text, device, direction, offset) in samples {
        let content = ClipContent.text(text)
        let item = engine.history.add(content, hash: content.hash, deviceName: device, direction: direction,
                                      date: Date().addingTimeInterval(offset))
        if direction == .sent { engine.history.setDelivered(item.id, count: 3) }
    }
    engine.log.add("بدأ CoShare على «\(engine.settings.deviceName)»")
    engine.log.add("متصل: iPhone إيهاب")
    engine.log.add("استُلم نص من iPhone إيهاب — جاهز للصق")
    engine.log.add("تعذّر الإرسال إلى iPad: انتهت المهلة", isError: true)

    for (name, tab, scheme) in [("history-light", MenuView.Tab.history, NSAppearance.Name.aqua),
                                ("history-dark", .history, .darkAqua),
                                ("devices", .devices, .aqua),
                                ("devices-dark", .devices, .darkAqua),
                                ("log", .log, .aqua),
                                ("settings", .settings, .aqua)] {
        let view = MenuView(tab: tab)
            .background(Color(nsColor: .windowBackgroundColor))
            .environmentObject(engine)
            .environmentObject(engine.history)
            .environmentObject(engine.settings)
            .environmentObject(engine.log)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 380, height: 540)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: scheme)
        window.backgroundColor = scheme == .darkAqua ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.96, alpha: 1)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { continue }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let url = directory.appendingPathComponent("\(name).png")
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("wrote \(url.path)")
    }
    engine.history.clear()
    engine.log.clear()
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/snapshots")
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
Task { @MainActor in
    renderSnapshots(into: output)
    exit(0)
}
app.run()
