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
//   quietnow <minutes>          quiet hours starting now, every day · quietoff · resume · state
//   retentiontest               checks that old clips and their image files are deleted on time
//   presencetest                checks the "device in / out" notifications logic with a fake clock
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
        case "retentiontest":
            retentionTest()
        case "presencetest":
            presenceTest()
        case "quietnow":
            let calendar = Calendar.current
            let now = calendar.dateComponents([.hour, .minute], from: Date())
            let start = (now.hour ?? 0) * 60 + (now.minute ?? 0)
            engine.settings.quietSchedule = QuietSchedule(days: Set(1...7), start: start, end: (start + (Int(argument) ?? 2)) % (24 * 60))
            engine.settings.quietEnabled = true
        case "quietoff":
            engine.settings.quietEnabled = false
        case "resume":
            engine.resumeToday()
        case "state":
            say("STATE \(engine.presence)")
        case "vector":
            // Interop vector for other implementations: key + tag for a group id and password.
            let words = argument.split(separator: " ").map(String.init)
            let key = GroupKey(groupID: words[0], password: words[1])
            let keyHex = key.key.withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined()
            let header = WireHeader(type: .hello, senderID: "VECTOR", senderName: "Vector", platform: .mac, clip: nil,
                                    listenPort: 47331, groups: [AdvertisedGroup(id: words[0], tag: key.tag, name: "G")], quiet: nil)
            let frame = (try? WireMessage(header: header, payload: Data("مرحبا".utf8)).frame(using: key)) ?? Data()
            say("VECTOR key=\(keyHex) tag=\(key.tag) frame=\(frame.base64EncodedString())")
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


/// Old clips — and the image files behind them — must disappear when they pass the retention period,
/// a longer period must keep them, and the setting must survive a restart.
@MainActor
func retentionTest() {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("coshare-retention-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let png = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) + Data(repeating: 7, count: 2000)
    var results: [(String, Bool)] = []
    func add(_ store: HistoryStore, _ content: ClipContent, hoursAgo: Double) {
        store.add(content, hash: content.hash, deviceName: "T", direction: .received, date: Date().addingTimeInterval(-hoursAgo * 3600))
    }

    // A week: items from 2 and 50 hours ago stay.
    let store = HistoryStore(directory: dir, retentionHours: 168)
    add(store, .text("now"), hoursAgo: 0)
    add(store, .text("two hours"), hoursAgo: 2)
    add(store, .image(png, uti: "public.png"), hoursAgo: 2.5)
    add(store, .image(png + Data([1]), uti: "public.png"), hoursAgo: 50)
    store.purge()
    results.append(("week keeps all 4 items", store.items.count == 4))
    results.append(("week keeps both image files", store.blobFileCount == 2))
    store.saveNow()

    // Reopening with a week must not drop the 50-hour item (the setting applies before the first purge).
    let reopened = HistoryStore(directory: dir, retentionHours: 168)
    results.append(("restart with a week keeps 4", reopened.items.count == 4))

    // One day: the 50-hour item and its image go.
    reopened.retention = 24 * 3600
    results.append(("one day drops the 50h item", reopened.items.count == 3))
    results.append(("one day removes its image file", reopened.blobFileCount == 1))

    // One hour: only "now" is left, and no image files remain.
    reopened.retention = 3600
    results.append(("one hour keeps only the newest", reopened.items.map(\.text) == ["now"]))
    results.append(("one hour leaves no image files", reopened.blobFileCount == 0))

    // The setting itself: clamped to 1 hour … 1 week, default one day.
    let defaults = UserDefaults(suiteName: "coshare.retentiontest.\(UUID().uuidString)")!
    let settings = AppSettings(defaults: defaults, defaultName: "T")
    results.append(("default is one day", settings.historyRetentionHours == 24))
    results.append(("default is 12-hour clock", settings.use24Hour == false))
    settings.historyRetentionHours = 1000
    results.append(("capped at a week", settings.historyRetentionHours == 168))
    settings.historyRetentionHours = 72
    results.append(("saved across restart", AppSettings(defaults: defaults, defaultName: "T").historyRetentionHours == 72))

    // Clock format.
    let date = Calendar.current.date(bySettingHour: 15, minute: 45, second: 12, of: Date())!
    results.append(("12h clock", Format.clock(date, h24: false).contains("3:45 PM")))
    results.append(("24h clock", Format.clock(date, h24: true).contains("15:45")))
    results.append(("12h log time", Format.time(date, h24: false).contains("3:45:12 PM")))

    for (name, ok) in results { say("RETENTION \(ok ? "PASS" : "FAIL") \(name)") }
    say("RETENTION \(results.allSatisfy(\.1) ? "ALL PASS" : "FAILED")")
}

@MainActor
func presenceTest() {
    let defaults = UserDefaults(suiteName: "coshare.presencetest.\(UUID().uuidString)")!
    var events: [PresenceWatch.Event] = []
    var results: [(String, Bool)] = []
    let watch = PresenceWatch(defaults: defaults)
    watch.onEvent = { events.append($0) }
    let t0 = Date()
    func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }
    let home = PresenceWatch.GroupRef(id: "G1", name: "البيت")
    let work = PresenceWatch.GroupRef(id: "G2", name: "الشغل")
    let a = PresenceWatch.Member(id: "A", name: "iPhone", groups: [home])
    let b = PresenceWatch.Member(id: "B", name: "Windows", groups: [home])
    func take() -> [PresenceWatch.Event] { defer { events.removeAll() }; return events }

    // Launch: what is already there is not news.
    watch.settle(now: t0)
    watch.update([a], now: at(1))
    results.append(("quiet while connecting", take().isEmpty))

    // A device seen for the first time in a group has joined.
    watch.update([a, b], now: at(25))
    results.append(("new device → joined", take() == [.init(kind: .joined, member: b)]))

    // Out for 15 s and back: no noise at all.
    watch.update([b], now: at(30))
    watch.tick(now: at(40))
    watch.update([a, b], now: at(45))
    watch.tick(now: at(90))
    results.append(("short drop → nothing", take().isEmpty))

    // Out for longer than the grace time: one "out", reason unknown.
    watch.update([b], now: at(50))
    watch.tick(now: at(79))
    let early = take()
    watch.tick(now: at(81))
    results.append(("no 'out' before 30 s", early.isEmpty))
    results.append(("gone 30 s → out (lost)", take() == [.init(kind: .left(.lost), member: a)]))

    // Back again: it has been here before, so "back", not "joined".
    watch.update([a, b], now: at(100))
    results.append(("returning device → back", take() == [.init(kind: .back, member: a)]))

    // Bye first, then it drops: "out" right away, with its quiet hours.
    let until = at(3600)
    watch.bye("A", until: until, now: at(110))
    watch.update([b], now: at(110))
    results.append(("bye (quiet) → out at once", take() == [.init(kind: .left(.quiet(until: until)), member: a)]))

    // Drops first, then its bye arrives: still one "out", with the reason, and nothing later.
    watch.update([], now: at(120))
    watch.bye("B", until: nil, now: at(121))
    watch.tick(now: at(200))
    results.append(("drop then bye → one out (paused)", take() == [.init(kind: .left(.paused), member: b)]))

    // This device reconnects (network change): drops pending at that moment are not reported.
    watch.update([a], now: at(300))
    _ = take()
    watch.update([], now: at(310))
    watch.settle(now: at(311))
    watch.tick(now: at(400))
    results.append(("own reconnect cancels pending out", take().isEmpty))

    // This device went offline on purpose and came back: nothing reported.
    watch.update([a, b], now: at(500))
    _ = take()
    watch.reset()
    watch.settle(now: at(600))
    watch.update([a, b], now: at(601))
    watch.tick(now: at(700))
    results.append(("own quiet hours → nothing", take().isEmpty))

    // Who was ever in a group survives a restart; a new group for a known device is "joined".
    let again = PresenceWatch(defaults: defaults)
    again.onEvent = { events.append($0) }
    again.update([a], now: at(800))
    results.append(("remembered after restart → back", take() == [.init(kind: .back, member: a)]))
    let aBoth = PresenceWatch.Member(id: "A", name: "iPhone", groups: [home, work])
    again.update([], now: at(810))
    again.update([aBoth], now: at(815))
    let joinedWork = take()
    results.append(("known device in a new group → joined that group",
                    joinedWork == [.init(kind: .joined, member: .init(id: "A", name: "iPhone", groups: [work]))]))

    // Words.
    let c = PresenceWatch.Member(id: "C", name: "Linux", groups: [home, work])
    let (joinTitle, joinBody) = PresenceNotifier.text(for: .init(kind: .joined, member: c), use24Hour: false)
    results.append(("joined text", joinTitle == "جهاز جديد انضم: Linux" && joinBody == "صار بمجموعات «البيت» و«الشغل»"))
    let (outTitle, outBody) = PresenceNotifier.text(for: .init(kind: .left(.lost), member: a), use24Hour: false)
    results.append(("out text", outTitle == "iPhone طلع" && outBody.hasPrefix("انقطع") && outBody.hasSuffix("بمجموعة «البيت»")))
    let quietBody = PresenceNotifier.text(for: .init(kind: .left(.quiet(until: until)), member: a), use24Hour: true).1
    results.append(("quiet text has the time", quietBody.contains("وقت الإيقاف لحد") && quietBody.contains(":")))

    // Settings: all on by default, saved.
    let settings = AppSettings(defaults: defaults, defaultName: "T")
    results.append(("on by default", settings.notifyDevices && settings.notifyJoins && settings.notifyLeaves))
    settings.notifyLeaves = false
    results.append(("saved", !AppSettings(defaults: defaults, defaultName: "T").notifyLeaves))

    for (name, ok) in results { say("PRESENCE \(ok ? "PASS" : "FAIL") \(name)") }
    say("PRESENCE \(results.allSatisfy(\.1) ? "ALL PASS" : "FAILED")")
}
