import Foundation
import Combine
import Network

/// Platform clipboard access (NSPasteboard on macOS, UIPasteboard on iOS).
protocol PasteboardBridge: AnyObject {
    var changeCount: Int { get }
    /// Why the last `read` came back empty although something was copied (e.g. iOS refused access).
    var lastReadProblem: String? { get }
    func read(includeImages: Bool, maxImageBytes: Int, skipConcealed: Bool) -> ClipContent?
    func write(_ content: ClipContent)
}

extension PasteboardBridge {
    var lastReadProblem: String? { nil }
}

/// Watches the local clipboard, pushes every new copy to all devices in this device's groups,
/// and applies clips that arrive from them.
@MainActor
final class SyncEngine: ObservableObject {
    static let shared = SyncEngine(pasteboard: PlatformPasteboard())

    enum Pulse { case idle, sent, received }

    @Published private(set) var peers: [Peer] = []
    @Published private(set) var pulse: Pulse = .idle
    @Published private(set) var isStarted = false

    let settings: AppSettings
    let history: HistoryStore
    let log: ActivityLog

    private let network = PeerNetwork()
    private let pasteboard: PasteboardBridge
    private var identity: LocalIdentity?
    private var keyCache: [String: GroupKey] = [:]
    private var networkGeneration = 0
    private var pollTimer: Timer?
    private var maintenanceTimer: Timer?
    private var pulseTask: Task<Void, Never>?
    private var lastChangeCount = -1
    private var lastReportedProblemCount = -1
    /// Hash/date of what is currently on this device's clipboard, whichever side it came from.
    private var currentHash: String?
    private var currentDate = Date.distantPast
    private var seenClipIDs: [UUID] = []
    private var cancellables = Set<AnyCancellable>()
    private let pathMonitor = NWPathMonitor()
    private var lastPathSignature: String?

    init(pasteboard: PasteboardBridge) {
        let environment = AppEnvironment.current
        self.pasteboard = pasteboard
        settings = AppSettings(defaults: environment.defaults, defaultName: DevicePlatform.defaultDeviceName)
        history = HistoryStore(directory: environment.dataDirectory)
        log = ActivityLog(directory: environment.dataDirectory)
        if let latest = history.items.first {
            currentHash = latest.hash
            currentDate = latest.date
        }
        network.onPeersChanged = { [weak self] peers in self?.updatePeers(peers) }
        network.onEvent = { [weak self] text, isError in self?.log.add(text, isError: isError) }
        network.onRequest = { [weak self] message, group in self?.handle(message, group: group) }
    }

    // MARK: Groups

    /// Devices that share at least one group with this one — they get every copy.
    var connectedPeers: [Peer] { peers.filter { sharedGroup(with: $0) != nil } }

    /// Groups advertised on the network that this device hasn't joined, with who is in them.
    var nearbyGroups: [NearbyGroup] {
        let mine = Set(settings.groups.map(\.id))
        var byID: [String: NearbyGroup] = [:]
        for peer in peers {
            for group in peer.groups where !mine.contains(group.id) {
                let key = group.id + group.tag
                byID[key, default: NearbyGroup(group: group, memberNames: [])].memberNames.append(peer.name)
            }
        }
        return byID.values.sorted { $0.group.name.localizedCaseInsensitiveCompare($1.group.name) == .orderedAscending }
    }

    /// Connected devices in one of this device's groups.
    func members(of group: GroupMembership) -> [Peer] {
        guard let secret = identity?.groups.first(where: { $0.id == group.id }) else { return [] }
        return peers.filter { Self.peer($0, isIn: secret) }
    }

    func createGroup(name: String, password: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw GroupError.nameMissing }
        guard password.count >= GroupMembership.minimumPasswordLength else { throw GroupError.passwordTooShort }
        settings.groups.append(GroupMembership(id: GroupMembership.newID(), name: name, password: password, joinedAt: Date()))
        log.add("أنشأت مجموعة «\(name)»")
        restartNetwork()
    }

    /// Checks the password against the tag the group advertises, then joins for good.
    func join(_ nearby: NearbyGroup, password: String) async throws {
        let group = nearby.group
        let key = await deriveKey(groupID: group.id, password: password)
        guard key.tag == group.tag else {
            log.add("كلمة سر خاطئة لمجموعة «\(group.name)»", isError: true)
            throw GroupError.wrongPassword
        }
        settings.groups.removeAll { $0.id == group.id }
        settings.groups.append(GroupMembership(id: group.id, name: group.name, password: password, joinedAt: Date()))
        log.add("انضممت لمجموعة «\(group.name)»")
        restartNetwork()
    }

    /// Joins from an invite link (QR code). The link carries the password, so no check is needed.
    func join(invite: GroupMembership) {
        settings.groups.removeAll { $0.id == invite.id }
        settings.groups.append(invite)
        log.add("انضممت لمجموعة «\(invite.name)» عن طريق الدعوة")
        restartNetwork()
    }

    func leave(_ group: GroupMembership) {
        settings.groups.removeAll { $0.id == group.id }
        log.add("غادرت مجموعة «\(group.name)»")
        restartNetwork()
    }

    func inviteURL(for group: GroupMembership) -> URL { GroupInvite.url(for: group) }

    private func sharedGroup(with peer: Peer) -> GroupSecret? {
        identity?.groups.first { Self.peer(peer, isIn: $0) }
    }

    /// Same group ID *and* same password (tag). Names aren't compared: Bonjour truncates long ones.
    private static func peer(_ peer: Peer, isIn group: GroupSecret) -> Bool {
        peer.groups.contains { $0.id == group.id && $0.tag == group.key.tag }
    }

    private func deriveKey(groupID: String, password: String) async -> GroupKey {
        let cacheKey = groupID + "\u{0}" + password
        if let cached = keyCache[cacheKey] { return cached }
        // PBKDF2 is deliberately slow; keep it off the main thread.
        let key = await Task.detached(priority: .userInitiated) { GroupKey(groupID: groupID, password: password) }.value
        keyCache[cacheKey] = key
        return key
    }

    // MARK: Lifecycle

    func start() {
        guard !isStarted else { return }
        isStarted = true
        log.add("بدأ CoShare على «\(settings.deviceName)»")
        // Whatever was copied before launch is old news; only new copies are shared.
        lastChangeCount = pasteboard.changeCount
        startNetwork()

        let poll = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollNow() }
        }
        poll.tolerance = 0.2
        RunLoop.main.add(poll, forMode: .common)
        pollTimer = poll

        maintenanceTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.history.purge()
                self?.log.purge()
            }
        }

        settings.$deviceName
            .dropFirst()
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.restartNetwork() }
            .store(in: &cancellables)

        pathMonitor.pathUpdateHandler = { [weak self] path in
            let lanInterfaces = path.availableInterfaces.filter { $0.type == .wifi || $0.type == .wiredEthernet }
            let signature = path.status == .satisfied
                ? lanInterfaces.map(\.name).joined(separator: ",") + "|" + path.gateways.map(\.debugDescription).joined(separator: ",")
                : "offline"
            Task { @MainActor in self?.networkPathChanged(signature) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "coshare.path"))
    }

    func restartNetwork() {
        guard isStarted else { return }
        startNetwork()
    }

    /// Looks for devices again without dropping the current connections.
    func refreshDiscovery() {
        network.refreshDiscovery()
    }

    private func startNetwork() {
        networkGeneration += 1
        let generation = networkGeneration
        let trimmedName = settings.deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmedName.isEmpty ? DevicePlatform.defaultDeviceName : trimmedName
        let memberships = settings.groups
        let id = settings.deviceID
        let platform = DevicePlatform.current
        Task {
            var secrets: [GroupSecret] = []
            for group in memberships {
                secrets.append(GroupSecret(membership: group, key: await deriveKey(groupID: group.id, password: group.password)))
            }
            guard generation == self.networkGeneration else { return }
            let me = LocalIdentity(id: id, name: name, platform: platform, groups: secrets)
            self.identity = me
            self.network.start(me)
        }
    }

    private func networkPathChanged(_ signature: String) {
        defer { lastPathSignature = signature }
        guard let last = lastPathSignature, last != signature, signature != "offline" else { return }
        log.add("تغيّرت الشبكة — إعادة الاتصال")
        restartNetwork()
    }

    private func updatePeers(_ newPeers: [Peer]) {
        let oldPeers = connectedPeers
        let oldConnected = Set(oldPeers.map(\.id))
        peers = newPeers
        let nowConnected = connectedPeers
        let newIDs = Set(nowConnected.map(\.id))
        for peer in nowConnected where !oldConnected.contains(peer.id) {
            log.add("متصل: \(peer.name)\(peer.isDirect ? " (اتصال مباشر)" : "")")
        }
        for id in oldConnected where !newIDs.contains(id) {
            log.add("انقطع: \(oldPeers.first { $0.id == id }?.name ?? "جهاز")")
        }
        // A device that just (re)joined may hold something copied while we couldn't see each other.
        // pullLatest only applies it if it is newer than what we already have.
        let joined = nowConnected.filter { !oldConnected.contains($0.id) }
        if !joined.isEmpty {
            Task { await pullLatest(from: joined) }
        }
    }

    // MARK: Local clipboard → other devices

    /// Checks the clipboard for a new copy. Returns true when something new was found.
    @discardableResult
    func pollNow(force: Bool = false) -> Bool {
        guard isStarted else { return false }
        let count = pasteboard.changeCount
        guard force || count != lastChangeCount else { return false }
        lastChangeCount = count
        guard !settings.paused else { return false }
        guard let content = pasteboard.read(includeImages: settings.syncImages,
                                            maxImageBytes: settings.maxImageBytes,
                                            skipConcealed: settings.skipConcealed)
        else {
            if let problem = pasteboard.lastReadProblem, lastReportedProblemCount != count {
                lastReportedProblemCount = count
                log.add(problem, isError: true)
            }
            return false
        }
        let hash = content.hash
        guard hash != currentHash else { return false }
        currentHash = hash
        currentDate = Date()
        Task { await broadcast(content, hash: hash) }
        return true
    }

    /// Sends whatever is on the clipboard right now, even if it was already sent.
    @discardableResult
    func sendCurrentClipboard() async -> Int {
        guard let content = pasteboard.read(includeImages: settings.syncImages,
                                            maxImageBytes: settings.maxImageBytes,
                                            skipConcealed: false)
        else {
            log.add(pasteboard.lastReadProblem ?? "الحافظة فارغة أو محتواها غير مدعوم", isError: true)
            return 0
        }
        lastChangeCount = pasteboard.changeCount
        return await send(content, copyLocally: false)
    }

    /// Sends arbitrary content (used by Shortcuts actions), optionally putting it on this clipboard too.
    @discardableResult
    func send(_ content: ClipContent, copyLocally: Bool) async -> Int {
        if copyLocally {
            pasteboard.write(content)
            lastChangeCount = pasteboard.changeCount
        }
        let hash = content.hash
        currentHash = hash
        currentDate = Date()
        await waitForPeers(timeout: 3)
        return await broadcast(content, hash: hash)
    }

    /// Re-copies an item from history; the next poll picks it up and shares it.
    func copyToClipboard(_ item: HistoryItem) {
        guard let content = history.content(of: item) else { return }
        pasteboard.write(content)
    }

    @discardableResult
    private func broadcast(_ content: ClipContent, hash: String) async -> Int {
        let item = history.add(content, hash: hash, deviceName: settings.deviceName, direction: .sent, date: currentDate)
        guard let me = await readyIdentity() else { return 0 }
        guard !me.groups.isEmpty else {
            log.add("نُسخ \(content.label) — هذا الجهاز ليس في أي مجموعة بعد")
            return 0
        }
        let targets = connectedPeers
        guard !targets.isEmpty else {
            log.add("نُسخ \(content.label) — لا توجد أجهزة متصلة حالياً")
            return 0
        }
        let meta = ClipMeta(id: UUID(), kind: content.kind, uti: content.uti, hash: hash, createdAt: currentDate,
                            origin: me.name)
        let message = WireMessage(header: header(.clip, me, clip: meta), payload: content.payload)
        let results = await exchange(message, with: targets, timeout: Self.timeout(forBytes: content.payload.count))
        let delivered = results.filter { $0.reply?.header.type == .ack }.count
        history.setDelivered(item.id, count: delivered)
        log.add("أُرسل \(content.label) إلى \(delivered) من \(targets.count) أجهزة")
        for result in results where result.reply == nil {
            log.add("تعذّر الإرسال إلى \(result.peer.name): \(result.error?.localizedDescription ?? "")", isError: true)
        }
        if delivered > 0 { flash(.sent) }
        return delivered
    }

    // MARK: Other devices → local clipboard

    private func handle(_ message: WireMessage, group: GroupSecret) -> WireMessage? {
        guard let me = identity else { return nil }
        switch message.header.type {
        case .clip:
            if let meta = message.header.clip,
               let content = ClipContent(kind: meta.kind, uti: meta.uti, payload: message.payload) {
                apply(content, meta: meta, from: meta.origin ?? message.header.senderName)
            }
            return WireMessage(header: header(.ack, me))
        case .pullLatest:
            guard let item = history.items.first, let content = history.content(of: item) else {
                return WireMessage(header: header(.nothing, me))
            }
            let meta = ClipMeta(id: item.id, kind: item.kind, uti: item.uti, hash: item.hash, createdAt: item.date,
                                origin: item.deviceName)
            return WireMessage(header: header(.latest, me, clip: meta), payload: content.payload)
        case .ack, .latest, .nothing, .hello:
            return WireMessage(header: header(.ack, me))
        }
    }

    @discardableResult
    private func apply(_ content: ClipContent, meta: ClipMeta, from sender: String) -> Bool {
        guard !seenClipIDs.contains(meta.id) else { return false }
        seenClipIDs.append(meta.id)
        if seenClipIDs.count > 200 { seenClipIDs.removeFirst(50) }
        guard !settings.paused else {
            log.add("تم تجاهل نسخة من \(sender) لأن المزامنة متوقفة مؤقتاً")
            return false
        }
        guard meta.hash != currentHash else { return false }
        guard content.kind == .text || settings.syncImages else { return false }

        pasteboard.write(content)
        lastChangeCount = pasteboard.changeCount
        currentHash = meta.hash
        currentDate = meta.createdAt
        history.add(content, hash: meta.hash, deviceName: sender, direction: .received, date: meta.createdAt)
        log.add("استُلم \(content.label) من \(sender) — جاهز للصق")
        flash(.received)
        return true
    }

    /// Asks devices for their newest clip and applies it if it is newer than ours.
    /// Used when the iPhone app returns to the foreground and whenever a device (re)appears.
    @discardableResult
    func pullLatest(from specificPeers: [Peer]? = nil) async -> Bool {
        guard let me = await readyIdentity() else { return false }
        if specificPeers == nil { await waitForPeers(timeout: 3) }
        let targets = specificPeers ?? connectedPeers
        guard !targets.isEmpty else { return false }
        let results = await exchange(WireMessage(header: header(.pullLatest, me)), with: targets, timeout: 20)
        let newest = results
            .compactMap { $0.reply }
            .filter { $0.header.type == .latest && $0.header.clip != nil }
            .max { $0.header.clip!.createdAt < $1.header.clip!.createdAt }
        guard let message = newest, let meta = message.header.clip, meta.createdAt > currentDate,
              let content = ClipContent(kind: meta.kind, uti: meta.uti, payload: message.payload)
        else { return false }
        return apply(content, meta: meta, from: meta.origin ?? message.header.senderName)
    }

    // MARK: Helpers

    func waitForPeers(timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while connectedPeers.isEmpty && Date() < deadline {
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
    }

    private func readyIdentity() async -> LocalIdentity? {
        let deadline = Date().addingTimeInterval(5)
        while identity == nil && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return identity
    }

    private struct ExchangeResult {
        let peer: Peer
        let reply: WireMessage?
        let error: Error?
    }

    /// Sends `message` to every target, sealed with the group each one shares with us
    /// (sealed once per group, not once per device).
    private func exchange(_ message: WireMessage, with targets: [Peer], timeout: TimeInterval) async -> [ExchangeResult] {
        var frames: [String: Data] = [:]
        var jobs: [(Peer, GroupKey, Data)] = []
        var failures: [ExchangeResult] = []
        for peer in targets {
            guard let group = sharedGroup(with: peer) else { continue }
            if frames[group.id] == nil {
                do {
                    frames[group.id] = try message.frame(using: group.key)
                } catch {
                    failures.append(ExchangeResult(peer: peer, reply: nil, error: error))
                    continue
                }
            }
            jobs.append((peer, group.key, frames[group.id]!))
        }
        let network = self.network
        let results = await withTaskGroup(of: ExchangeResult.self) { taskGroup in
            for (peer, key, frame) in jobs {
                taskGroup.addTask {
                    do {
                        let reply = try await network.exchange(frame, key: key, with: peer, timeout: timeout)
                        return ExchangeResult(peer: peer, reply: reply, error: nil)
                    } catch {
                        return ExchangeResult(peer: peer, reply: nil, error: error)
                    }
                }
            }
            var results: [ExchangeResult] = []
            for await result in taskGroup { results.append(result) }
            return results
        }
        return results + failures
    }

    private func header(_ type: MessageType, _ me: LocalIdentity, clip: ClipMeta? = nil) -> WireHeader {
        WireHeader(type: type, senderID: me.id, senderName: me.name, platform: me.platform, clip: clip)
    }

    private func flash(_ value: Pulse) {
        pulse = value
        pulseTask?.cancel()
        pulseTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            self?.pulse = .idle
        }
    }

    /// Generous timeout for big screenshots on slow Wi-Fi.
    private static func timeout(forBytes bytes: Int) -> TimeInterval {
        min(120, 8 + Double(bytes) / 1_000_000)
    }
}
