// Headless CoShare peer for end-to-end testing without a phone.
// It runs the real sync engine (Bonjour, encryption, history) with an in-memory clipboard
// and takes commands from a text file, one per line:
//   copy <text>       simulate copying text on this device
//   copyimg <path>    simulate copying an image file
//   pull              ask other devices for their newest clip
//   create <group> <password>   create a group
//   join <group> <password>     join a group seen on the network
//   leave <group>               leave a group
//   groups | nearby | peers | history   print state
//   qrtest                      encode an invite as QR, decode it with Vision, check it round-trips
// COSHARE_NO_BONJOUR=1 disables Bonjour (direct mode), COSHARE_PORT=<n> sets the listening port,
// COSHARE_HOSTS=host:port,… are extra addresses to greet (like a hotspot gateway).
//   quit
// Build & run: scripts/test-peer.sh
import Foundation
import Vision

typealias PlatformPasteboard = FakePasteboard

extension DevicePlatform {
    static var current: DevicePlatform { .iphone }
    static var defaultDeviceName: String { ProcessInfo.processInfo.environment["COSHARE_NAME"] ?? "TestPeer" }
}

final class FakePasteboard: PasteboardBridge {
    static var instance: FakePasteboard!

    private(set) var changeCount = 0
    private var content: ClipContent?

    init() { FakePasteboard.instance = self }

    func read(includeImages: Bool, maxImageBytes: Int, skipConcealed: Bool) -> ClipContent? { content }

    func write(_ content: ClipContent) {
        self.content = content
        changeCount += 1
        say("PASTEBOARD <- \(describe(content))")
    }

    func simulateCopy(_ content: ClipContent) {
        self.content = content
        changeCount += 1
    }
}

func describe(_ content: ClipContent) -> String {
    switch content {
    case .text(let string): return "text \"\(string)\""
    case .image(let data, let uti): return "image \(uti) \(data.count) bytes sha=\(content.hash.prefix(12))"
    }
}

func say(_ line: String) {
    print(line)
    fflush(stdout)
}

@MainActor
final class CommandReader {
    private let url: URL
    private var processed = 0
    private var timer: Timer?

    init(path: String) {
        url = URL(fileURLWithPath: path)
        FileManager.default.createFile(atPath: path, contents: nil)
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
            Task { @MainActor in self.tick() }
        }
    }

    private func tick() {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard lines.count > processed else { return }
        for line in lines[processed...] { run(line) }
        processed = lines.count
    }

    private func run(_ line: String) {
        let engine = SyncEngine.shared
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let argument = parts.count > 1 ? parts[1] : ""
        say("> \(line)")
        switch parts.first ?? "" {
        case "copy":
            FakePasteboard.instance.simulateCopy(.text(argument))
        case "copyimg":
            guard let data = FileManager.default.contents(atPath: argument) else { say("no such file"); return }
            FakePasteboard.instance.simulateCopy(.image(data, uti: "public.png"))
        case "pull":
            Task { say("PULL updated=\(await engine.pullLatest())") }
        case "peers":
            say("PEERS " + engine.peers.map { "\($0.name)[\($0.isDirect ? "direct" : "bonjour")]" }.joined(separator: ", ")
                + " | CONNECTED " + engine.connectedPeers.map(\.name).joined(separator: ", "))
        case "history":
            for item in engine.history.items {
                say("HISTORY \(item.direction.rawValue) \(item.kind.rawValue) from=\(item.deviceName) \(item.text ?? "\(item.byteCount) bytes") delivered=\(item.deliveredTo.map(String.init) ?? "-")")
            }
        case "create":
            let words = argument.split(separator: " ").map(String.init)
            do { try engine.createGroup(name: words[0], password: words[1]); say("CREATE ok") } catch { say("CREATE failed \(error.localizedDescription)") }
        case "join":
            let words = argument.split(separator: " ").map(String.init)
            guard let nearby = engine.nearbyGroups.first(where: { $0.group.name == words[0] }) else { say("JOIN no such group"); return }
            Task {
                do { try await engine.join(nearby, password: words[1]); say("JOIN ok \(words[0])") } catch { say("JOIN failed \(error.localizedDescription)") }
            }
        case "leave":
            guard let group = engine.settings.groups.first(where: { $0.name == argument }) else { say("LEAVE no such group"); return }
            engine.leave(group)
            say("LEAVE ok")
        case "qrtest":
            let invite = GroupMembership(id: GroupMembership.newID(), name: "أجهزة إيهاب · Test", password: "p@ss wörd/&=?#1", joinedAt: Date())
            let url = GroupInvite.url(for: invite)
            for scale in [10.0, 4.0, 2.0] {
                guard let image = GroupInvite.qrImage(for: url, scale: scale) else { say("QR encode failed"); return }
                let payload = QRScanner.detect(in: VNImageRequestHandler(cgImage: image, options: [:]))
                let decoded = payload.flatMap(URL.init(string:)).flatMap(GroupInvite.parse)
                let ok = decoded?.id == invite.id && decoded?.name == invite.name && decoded?.password == invite.password
                say("QRTEST \(image.width)px decoded=\(payload != nil) roundtrip=\(ok)")
            }
        case "groups":
            say("GROUPS " + engine.settings.groups.map { "\($0.name)[\(engine.members(of: $0).map(\.name).joined(separator: ","))]" }.joined(separator: " "))
        case "nearby":
            say("NEARBY " + engine.nearbyGroups.map { "\($0.group.name)(\($0.memberNames.joined(separator: ",")))" }.joined(separator: " "))
        case "quit":
            exit(0)
        default:
            say("unknown command")
        }
    }
}

let commandsPath = ProcessInfo.processInfo.environment["COSHARE_CMDS"] ?? "/tmp/coshare-test-commands.txt"
Task { @MainActor in
    let engine = SyncEngine.shared
    engine.history.clear()
    engine.start()
    let reader = CommandReader(path: commandsPath)
    reader.start()
    objc_setAssociatedObject(engine, "reader", reader, .OBJC_ASSOCIATION_RETAIN)
    say("READY name=\(engine.settings.deviceName) commands=\(commandsPath)")
}
RunLoop.main.run()
