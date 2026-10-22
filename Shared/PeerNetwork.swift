import Foundation
import Network

struct Peer: Identifiable, Equatable, @unchecked Sendable {
    let id: String
    var name: String
    var platform: DevicePlatform
    /// Groups the device advertises (or told us about in a hello).
    var groups: [AdvertisedGroup]
    var endpoint: NWEndpoint
    /// Found by contacting its address directly rather than through Bonjour (hotspots, filtered networks).
    var isDirect: Bool
    /// Hours when that device is off the network on purpose.
    var quiet: QuietSchedule? = nil
}

struct LocalIdentity: @unchecked Sendable {
    let id: String
    let name: String
    let platform: DevicePlatform
    let groups: [GroupSecret]
    /// Shared with other devices so they don't call during these hours.
    var quiet: QuietSchedule? = nil

    /// Opens a frame with whichever of our group keys fits; nil if it belongs to no group of ours.
    func open(_ sealed: Data) -> (WireMessage, GroupSecret)? {
        for group in groups {
            if let message = try? WireMessage(sealed: sealed, using: group.key) { return (message, group) }
        }
        return nil
    }
}

/// Finds devices and talks to them with a tiny request/reply protocol over short-lived TCP connections.
/// Every device listens on a (preferably fixed) port and is found in three ways:
///  1. Bonjour browsing (normal Wi-Fi),
///  2. a short fresh Bonjour probe every 30 s (long-running browses go quiet for up to an hour),
///  3. direct "hello" connections to the network gateway and to addresses seen before — this is what
///     makes a laptop on a phone's hotspot, or a network that filters Bonjour, still work.
/// There is no server and nothing leaves the local network.
final class PeerNetwork: @unchecked Sendable {
    static let serviceType = "_coshare._tcp"
    /// Fixed port so devices can reach each other by address alone (falls back to any free port).
    static var preferredPort: UInt16 { AppEnvironment.current.portOverride ?? 47331 }

    var onPeersChanged: (@MainActor ([Peer]) -> Void)?
    var onRequest: (@MainActor (WireMessage, GroupSecret) async -> WireMessage?)?
    var onEvent: (@MainActor (String, Bool) -> Void)?
    /// A device said bye: quiet until the date, or paused when there is none.
    var onBye: (@MainActor (String, Date?) -> Void)?

    private let queue = DispatchQueue(label: "coshare.network", qos: .userInitiated)
    private var listener: NWListener?
    private var listenPort: UInt16 = 0
    /// The port we listen on, sent along in a bye so the other side can stop calling it.
    var currentListenPort: UInt16 { queue.sync { listenPort } }
    private var browser: NWBrowser?
    private var probe: NWBrowser?
    private var timers: [DispatchSourceTimer] = []
    private let pathMonitor = NWPathMonitor()
    private var gateways: [String] = []
    private var browsedPeers: [String: Peer] = [:]
    private var probedPeers: [String: Peer] = [:]
    private var directPeers: [String: (peer: Peer, seen: Date)] = [:]
    /// Last time each device answered us or called us (hello, clip, anything we could decrypt).
    private var lastContact: [String: Date] = [:]
    /// When each device listed by Bonjour first showed up (this session).
    private var firstSeen: [String: Date] = [:]
    /// A device of our groups that hasn't been heard from for this long is gone, even if Bonjour
    /// still lists it (it keeps a vanished device for a long time when Wi-Fi drops or it sleeps).
    private static let liveness: TimeInterval = 60
    /// Devices that said "bye, quiet until …", and the addresses they said it from.
    private var silenced: [String: Date] = [:]
    private var silencedAddresses: [String: (deviceID: String, until: Date)] = [:]
    /// When each device said bye. Its goodbye takes a moment to reach Bonjour, so an advertisement
    /// seen right after is the old one, not the device coming back (a hello still is).
    private var byeAt: [String: Date] = [:]
    private var generation = 0
    private let lock = NSLock()
    private var _identity: LocalIdentity?

    private var identity: LocalIdentity? {
        get { lock.lock(); defer { lock.unlock() }; return _identity }
        set { lock.lock(); _identity = newValue; lock.unlock() }
    }

    init() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            // Gateways are where a hotspot's phone lives (172.20.10.1 on iPhone, 192.168.43.1 on Android…).
            self.gateways = path.gateways.compactMap { endpoint in
                if case let .hostPort(host, _) = endpoint, case .ipv4 = host { return "\(host)" }
                return nil
            }
            self.runDirectProbe()
        }
        pathMonitor.start(queue: queue)
    }

    func start(_ me: LocalIdentity) {
        queue.async { [self] in
            tearDown()
            identity = me
            generation += 1
            startListener(me, generation, port: Self.preferredPort)
            if !AppEnvironment.current.noBonjour { startBrowser(me, generation) }
            startTimers(me, generation)
            runDirectProbe()
        }
    }

    /// Looks again right now (e.g. when the iPhone app returns to the foreground).
    func refreshDiscovery() {
        queue.async { [self] in
            guard let me = identity else { return }
            if !AppEnvironment.current.noBonjour { runBonjourProbe(me, generation) }
            runDirectProbe()
        }
    }

    func stop() {
        queue.async { [self] in
            tearDown()
            generation += 1
            publish([])
        }
    }

    // MARK: Outgoing

    /// Connects to a peer, sends one frame sealed with `key` and waits for its reply.
    func exchange(_ frame: Data, key: GroupKey, with peer: Peer, timeout: TimeInterval) async throws -> WireMessage {
        let connection = NWConnection(to: peer.endpoint, using: Self.parameters(for: peer.endpoint))
        let framed = FramedConnection(connection, queue: queue, timeout: timeout)
        defer { connection.cancel() }
        try await framed.open()
        rememberAddress(of: peer.id, from: connection)
        try await framed.send(frame)
        let reply = try await framed.receiveFrame()
        markContact(peer.id)
        return try WireMessage(sealed: reply, using: key)
    }

    // MARK: Listener

    /// `attempt` counts retries of the fixed port: right after a restart the old listener may not
    /// have released it yet, and giving up too early would break direct (hotspot) connections.
    private func startListener(_ me: LocalIdentity, _ gen: Int, port: UInt16?, attempt: Int = 0) {
        do {
            let parameters = Self.parameters()
            parameters.allowLocalEndpointReuse = true
            let listener = try port.flatMap(NWEndpoint.Port.init(rawValue:)).map { try NWListener(using: parameters, on: $0) }
                ?? NWListener(using: parameters)
            if !AppEnvironment.current.noBonjour {
                var txt = NWTXTRecord()
                txt["n"] = me.name
                txt["p"] = me.platform.rawValue
                txt["i"] = me.id
                txt["v"] = "2"
                for (index, group) in me.groups.prefix(8).enumerated() { txt["g\(index)"] = group.advertised.txtValue }
                if let quiet = me.quiet { txt["q"] = quiet.txtValue }
                listener.service = NWListener.Service(name: me.id, type: Self.serviceType, domain: nil, txtRecord: txt)
            }
            listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, gen == self.generation else { return }
                switch state {
                case .ready:
                    self.listenPort = listener?.port?.rawValue ?? 0
                    self.emit("جاهز للاستقبال على المنفذ \(self.listenPort)")
                case .failed(let error):
                    self.listener?.cancel()
                    if let port, attempt < 12 {
                        self.queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                            guard let self, gen == self.generation else { return }
                            self.startListener(me, gen, port: port, attempt: attempt + 1)
                        }
                    } else if port != nil {
                        // Something else really owns the port: Bonjour still works on any free port.
                        self.emit("المنفذ \(Self.preferredPort) مشغول — الاتصال المباشر (Hotspot) قد لا يعمل", error: true)
                        self.startListener(me, gen, port: nil)
                    } else {
                        self.emit("توقف الاستقبال (\(error.localizedDescription)) — إعادة المحاولة", error: true)
                        self.queue.asyncAfter(deadline: .now() + 2) { [weak self] in
                            guard let self, gen == self.generation else { return }
                            self.startListener(me, gen, port: Self.preferredPort)
                        }
                    }
                default:
                    break
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            if let port, attempt < 12 {
                queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self, gen == self.generation else { return }
                    self.startListener(me, gen, port: port, attempt: attempt + 1)
                }
                return
            }
            if port != nil { startListener(me, gen, port: nil); return }
            emit("تعذّر فتح منفذ الاستقبال: \(error.localizedDescription)", error: true)
            queue.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, gen == self.generation else { return }
                self.startListener(me, gen, port: Self.preferredPort)
            }
        }
    }

    private func serve(_ connection: NWConnection) {
        guard let me = identity else { connection.cancel(); return }
        let framed = FramedConnection(connection, queue: queue, timeout: 120)
        connection.start(queue: queue)
        Task {
            defer { connection.cancel() }
            // Anything we can't decrypt (another group, a stranger, a port scan) is dropped silently.
            guard let sealed = try? await framed.receiveFrame(), let opened = me.open(sealed) else { return }
            let (request, group) = opened
            if request.header.type != .bye { markContact(request.header.senderID) }
            do {
                let reply: WireMessage?
                if request.header.type == .hello {
                    learnDirectPeer(request.header, remote: connection.endpoint, group: group)
                    reply = helloMessage(me)
                } else if request.header.type == .bye {
                    silence(request.header.senderID, until: request.header.quietUntil, name: request.header.senderName,
                            from: connection.endpoint, listenPort: request.header.listenPort)
                    reply = WireMessage(header: WireHeader(type: .ack, senderID: me.id, senderName: me.name, platform: me.platform))
                } else {
                    reply = await onRequest?(request, group)
                }
                guard let reply else { return }
                try await framed.send(reply.frame(using: group.key))
                await framed.waitForPeerToClose()
            } catch {
                emit("خطأ أثناء الرد على «\(request.header.senderName)»: \(error.localizedDescription)", error: true)
            }
        }
    }

    // MARK: Bonjour

    private func startBrowser(_ me: LocalIdentity, _ gen: Int) {
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: Self.parameters())
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, gen == self.generation else { return }
            self.browsedPeers = self.peers(from: results, me: me)
            self.publishMerged()
        }
        browser.stateUpdateHandler = { [weak self] state in
            guard let self, gen == self.generation else { return }
            switch state {
            case .waiting(let error):
                self.emit("البحث عن الأجهزة متوقف: \(error.localizedDescription) — تأكد من إذن «الشبكة المحلية»", error: true)
            case .failed(let error):
                self.emit("فشل البحث عن الأجهزة (\(error.localizedDescription)) — إعادة المحاولة", error: true)
                self.queue.asyncAfter(deadline: .now() + 3) { [weak self] in
                    guard let self, gen == self.generation else { return }
                    self.browser?.cancel()
                    self.startBrowser(me, gen)
                }
            default:
                break
            }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    private func startTimers(_ me: LocalIdentity, _ gen: Int) {
        func every(_ seconds: Int, _ work: @escaping () -> Void) {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .seconds(seconds), repeating: .seconds(seconds), leeway: .seconds(2))
            timer.setEventHandler { [weak self] in
                guard let self, gen == self.generation else { return }
                work()
            }
            timer.resume()
            timers.append(timer)
        }
        if !AppEnvironment.current.noBonjour {
            every(30) { [weak self] in self?.runBonjourProbe(me, gen) }
        }
        every(15) { [weak self] in self?.runDirectProbe() }
    }

    private func runBonjourProbe(_ me: LocalIdentity, _ gen: Int) {
        guard probe == nil else { return }
        let probe = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: Self.parameters())
        probe.start(queue: queue)
        self.probe = probe
        queue.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            let found = self.peers(from: probe.browseResults, me: me)
            probe.cancel()
            if self.probe === probe { self.probe = nil }
            guard gen == self.generation else { return }
            self.probedPeers = found
            self.publishMerged()
        }
    }

    private func peers(from results: Set<NWBrowser.Result>, me: LocalIdentity) -> [String: Peer] {
        var byID: [String: Peer] = [:]
        for result in results {
            // Results can show up before their TXT record resolves; wait for it.
            guard case let .service(name, _, _, _) = result.endpoint,
                  case let .bonjour(txt) = result.metadata, txt["v"] == "2"
            else { continue }
            // Skip ourselves — including a second copy of this app, which Bonjour renames "<id> (2)".
            if name == me.id || txt["i"] == me.id || name.hasPrefix(me.id + " (") { continue }
            let groups = (0..<8).compactMap { txt["g\($0)"].flatMap(AdvertisedGroup.init(txtValue:)) }
            let id = txt["i"] ?? name
            if let said = byeAt[id], Date().timeIntervalSince(said) < 10 { continue }
            let quiet = txt["q"].flatMap(QuietSchedule.init(txtValue:))
            byID[id] = Peer(id: id, name: txt["n"] ?? name, platform: DevicePlatform(rawValue: txt["p"] ?? "") ?? .other,
                            groups: groups, endpoint: result.endpoint, isDirect: false, quiet: quiet)
            // Advertising again means it is back (e.g. "resume today").
            unsilence(id)
            saveSchedule(quiet, for: id)
        }
        return byID
    }

    // MARK: Direct contact (hotspot / no Bonjour)

    private func helloMessage(_ me: LocalIdentity) -> WireMessage {
        WireMessage(header: WireHeader(type: .hello, senderID: me.id, senderName: me.name, platform: me.platform,
                                       clip: nil, listenPort: listenPort, groups: me.groups.map(\.advertised), quiet: me.quiet))
    }

    /// Says hello to the gateway and to every address a group member had before. Whoever answers
    /// (with a key we share) becomes a peer even if Bonjour never shows it.
    private func runDirectProbe() {
        guard let me = identity, !me.groups.isEmpty else { return }
        let gen = generation
        let known = knownHosts().filter { !Self.isUnscopedLinkLocal($0.value) }
        // Never call a device during its quiet hours (or after it said bye): even a refused
        // connection would show up as traffic on a monitored work computer.
        let quietHosts = Set(known.filter { isQuiet($0.key) }.values)
        let now = Date()
        let silencedHosts = Set(silencedAddresses.filter { $0.value.until > now }.keys)
        let hosts = Set(gateways).union(known.values).union(AppEnvironment.current.extraHosts)
            .subtracting(quietHosts).subtracting(silencedHosts)
        for host in hosts {
            Task { await self.sayHello(to: host, me: me, gen: gen) }
        }
        // Group devices Bonjour lists but we haven't heard from lately: greet them where Bonjour says
        // they are. An answer keeps them listed (see isAlive) and teaches us their address.
        let quietSince = now.addingTimeInterval(-20)
        for peer in bonjourPeers().values where !isQuiet(peer.id) && (lastContact[peer.id] ?? .distantPast) < quietSince {
            let keys = me.groups.filter { group in peer.groups.contains { $0.id == group.id && $0.tag == group.key.tag } }
            guard !keys.isEmpty else { continue }
            Task { await self.hello(peer.endpoint, keys: keys, address: nil, me: me, gen: gen) }
        }
        // Forget direct peers that stopped answering.
        let cutoff = Date().addingTimeInterval(-50)
        directPeers = directPeers.filter { $0.value.seen > cutoff }
        publishMerged()
    }

    private func sayHello(to address: String, me: LocalIdentity, gen: Int) async {
        // "host" uses the standard port; "host:port" (tests) names one explicitly.
        let parts = address.split(separator: ":")
        let (host, port) = parts.count == 2 && UInt16(parts[1]) != nil
            ? (String(parts[0]), UInt16(parts[1])!) : (address, Self.preferredPort)
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        await hello(endpoint, keys: me.groups, address: address, me: me, gen: gen)
    }

    /// Greets one endpoint with each key in turn until one is understood. `address` is set for
    /// direct contact (the device then becomes a direct peer); nil for a device found by Bonjour.
    private func hello(_ endpoint: NWEndpoint, keys: [GroupSecret], address: String?, me: LocalIdentity, gen: Int) async {
        for group in keys {
            let connection = NWConnection(to: endpoint, using: Self.parameters(for: endpoint))
            let framed = FramedConnection(connection, queue: queue, timeout: 4)
            defer { connection.cancel() }
            // Nothing listening there (a normal router): stop. Connected but the other side couldn't
            // decrypt (it's in another group): try our next group's key.
            do { try await framed.open() } catch { return }
            let remote = connection.currentPath?.remoteEndpoint
            do {
                try await framed.send(helloMessage(me).frame(using: group.key))
                let reply = try WireMessage(sealed: try await framed.receiveFrame(), using: group.key)
                guard reply.header.type == .hello, reply.header.senderID != me.id else { return }
                let id = reply.header.senderID
                queue.async { [self] in
                    guard gen == generation else { return }
                    lastContact[id] = Date()
                    unsilence(id)
                    saveSchedule(reply.header.quiet, for: id)
                    if let address {
                        directPeers[id] = (Peer(id: id, name: reply.header.senderName, platform: reply.header.platform,
                                                groups: reply.header.groups ?? [], endpoint: endpoint, isDirect: true,
                                                quiet: reply.header.quiet), Date())
                        saveKnownHost(address, for: id)
                    } else if case let .hostPort(host, _)? = remote {
                        saveKnownHost("\(host)".components(separatedBy: "%").first ?? "\(host)", for: id)
                    }
                    publishMerged()
                }
                return
            } catch {
                continue
            }
        }
    }

    /// The other side of a hello: remember where the sender can be reached.
    private func learnDirectPeer(_ header: WireHeader, remote: NWEndpoint, group: GroupSecret) {
        // Our own hello coming back (an address that turned out to be this device).
        guard header.senderID != identity?.id else { return }
        guard case let .hostPort(host, _) = remote, let port = header.listenPort, port > 0,
              let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let hostString = "\(host)".components(separatedBy: "%").first ?? "\(host)"
        queue.async { [self] in
            let isNew = directPeers[header.senderID] == nil
            lastContact[header.senderID] = Date()
            unsilence(header.senderID)
            saveSchedule(header.quiet, for: header.senderID)
            directPeers[header.senderID] = (Peer(id: header.senderID, name: header.senderName, platform: header.platform,
                                                groups: header.groups ?? [group.advertised],
                                                endpoint: .hostPort(host: host, port: nwPort), isDirect: true,
                                                quiet: header.quiet), Date())
            saveKnownHost(hostString, for: header.senderID)
            if isNew { publishMerged() }
        }
    }

    private func markContact(_ deviceID: String) {
        queue.async { [self] in lastContact[deviceID] = Date() }
    }

    private func rememberAddress(of peerID: String, from connection: NWConnection) {
        guard case let .hostPort(host, _)? = connection.currentPath?.remoteEndpoint else { return }
        let hostString = "\(host)".components(separatedBy: "%").first ?? "\(host)"
        queue.async { [self] in saveKnownHost(hostString, for: peerID) }
    }

    private func silence(_ deviceID: String, until: Date?, name: String, from remote: NWEndpoint, listenPort: UInt16?) {
        queue.async { [self] in
            // Reported before the device drops out of the list, so its "out" can say why.
            let said = until
            Task { @MainActor [weak self] in self?.onBye?(deviceID, said) }
            let until = until ?? Date().addingTimeInterval(12 * 3600)
            byeAt[deviceID] = Date()
            silenced[deviceID] = until
            // Also its address, in case we only know it as an address (gateway, not yet greeted).
            if case let .hostPort(host, _) = remote {
                let hostString = "\(host)".components(separatedBy: "%").first ?? "\(host)"
                silencedAddresses[hostString] = (deviceID, until)
                if let listenPort { silencedAddresses["\(hostString):\(listenPort)"] = (deviceID, until) }
            }
            directPeers.removeValue(forKey: deviceID)
            browsedPeers.removeValue(forKey: deviceID)
            probedPeers.removeValue(forKey: deviceID)
            publishMerged()
        }
        emit("«\(name)» دخل وقت الإيقاف — لن نتصل به حتى يعود")
    }

    private func unsilence(_ deviceID: String) {
        byeAt.removeValue(forKey: deviceID)
        silenced.removeValue(forKey: deviceID)
        silencedAddresses = silencedAddresses.filter { $0.value.deviceID != deviceID }
    }

    /// Said bye recently, or inside the quiet hours it told us about.
    private func isQuiet(_ deviceID: String) -> Bool {
        if let until = silenced[deviceID], until > Date() { return true }
        let schedules = AppEnvironment.current.defaults.dictionary(forKey: "peerSchedules") as? [String: String] ?? [:]
        return schedules[deviceID].flatMap(QuietSchedule.init(txtValue:))?.window(containing: Date()) != nil
    }

    private func saveSchedule(_ quiet: QuietSchedule?, for deviceID: String) {
        var schedules = AppEnvironment.current.defaults.dictionary(forKey: "peerSchedules") as? [String: String] ?? [:]
        guard schedules[deviceID] != quiet?.txtValue else { return }
        schedules[deviceID] = quiet?.txtValue
        AppEnvironment.current.defaults.set(schedules, forKey: "peerSchedules")
    }

    private func knownHosts() -> [String: String] {
        AppEnvironment.current.defaults.dictionary(forKey: "knownHosts") as? [String: String] ?? [:]
    }

    private func saveKnownHost(_ host: String, for deviceID: String) {
        let isLoopback = host.hasPrefix("127.") || host == "::1"
        if isLoopback && AppEnvironment.current.extraHosts.isEmpty { return }
        // fe80:: means nothing without the interface it belongs to: calling it later always fails.
        if Self.isUnscopedLinkLocal(host) { return }
        var hosts = knownHosts()
        guard hosts[deviceID] != host else { return }
        hosts[deviceID] = host
        if hosts.count > 20 { hosts.removeValue(forKey: hosts.keys.first!) }
        AppEnvironment.current.defaults.set(hosts, forKey: "knownHosts")
    }

    // MARK: Helpers

    private func bonjourPeers() -> [String: Peer] {
        var peers = probedPeers
        for (id, peer) in browsedPeers { peers[id] = peer }
        return peers
    }

    /// A device of one of our groups is listed only while it answers: a minute from when it showed up
    /// or was last heard from. Devices of other groups are only shown as "nearby", so Bonjour is enough.
    private func isAlive(_ peer: Peer, now: Date) -> Bool {
        guard let me = identity,
              peer.groups.contains(where: { g in me.groups.contains { $0.id == g.id && $0.key.tag == g.tag } })
        else { return true }
        let heard = max(lastContact[peer.id] ?? .distantPast, firstSeen[peer.id] ?? .distantPast)
        return now.timeIntervalSince(heard) < Self.liveness
    }

    private static func isUnscopedLinkLocal(_ host: String) -> Bool {
        host.lowercased().hasPrefix("fe80:") && !host.contains("%")
    }

    private func publishMerged() {
        let now = Date()
        let bonjour = bonjourPeers()
        for id in bonjour.keys where firstSeen[id] == nil { firstSeen[id] = now }
        firstSeen = firstSeen.filter { bonjour[$0.key] != nil }
        // A device that said bye stays out until it is back (advertises or says hello again).
        var merged: [String: Peer] = directPeers.filter { (silenced[$0.key] ?? .distantPast) <= now }.mapValues(\.peer)
        for (id, peer) in bonjour where isAlive(peer, now: now) { merged[id] = peer }
        if let me = identity { merged.removeValue(forKey: me.id) }
        publish(merged.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
    }

    private func tearDown() {
        listener?.cancel()
        listener = nil
        browser?.cancel()
        browser = nil
        probe?.cancel()
        probe = nil
        timers.forEach { $0.cancel() }
        timers.removeAll()
        browsedPeers = [:]
        probedPeers = [:]
        directPeers = [:]
        lastContact = [:]
        firstSeen = [:]
    }

    private func publish(_ peers: [Peer]) {
        Task { @MainActor [weak self] in self?.onPeersChanged?(peers) }
    }

    private func emit(_ text: String, error: Bool = false) {
        Task { @MainActor [weak self] in self?.onEvent?(text, error) }
    }

    private static func parameters() -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.connectionTimeout = 5
        }
        return parameters
    }

    /// For calling out. A Bonjour name resolves to IPv6 link-local first, an address that can't be
    /// called again without its interface: IPv4 gives an address worth remembering (hotspots, and
    /// finding a device again within seconds after a network change).
    private static func parameters(for endpoint: NWEndpoint) -> NWParameters {
        let parameters = parameters()
        if case .service = endpoint, let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        return parameters
    }
}

/// async/await wrapper around NWConnection with one deadline for the whole exchange.
final class FramedConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let deadline: DispatchTime

    init(_ connection: NWConnection, queue: DispatchQueue, timeout: TimeInterval) {
        self.connection = connection
        self.queue = queue
        self.deadline = .now() + timeout
    }

    func open() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = Once()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.run { continuation.resume() }
                case .failed(let error), .waiting(let error):
                    once.run { continuation.resume(throwing: error) }
                case .cancelled:
                    once.run { continuation.resume(throwing: SyncError.connectionClosed) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
            armTimeout(once) { continuation.resume(throwing: SyncError.timeout) }
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = Once()
            connection.send(content: data, completion: .contentProcessed { error in
                once.run {
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            })
            armTimeout(once) { continuation.resume(throwing: SyncError.timeout) }
        }
    }

    func receiveFrame() async throws -> Data {
        let header = try await receive(exactly: 4)
        let length = Int(header.readUInt32(at: 0))
        guard length > 0, length <= WireMessage.maxFrameBytes else { throw SyncError.frameTooLarge }
        return try await receive(exactly: length)
    }

    /// Lets the client read our reply before the socket goes away.
    func waitForPeerToClose() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = Once()
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, _, _ in
                once.run { continuation.resume() }
            }
            queue.asyncAfter(deadline: .now() + 5) { once.run { continuation.resume() } }
        }
    }

    private func receive(exactly count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            let once = Once()
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                once.run {
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let data, data.count == count {
                        continuation.resume(returning: data)
                    } else {
                        continuation.resume(throwing: SyncError.connectionClosed)
                    }
                }
            }
            armTimeout(once) { continuation.resume(throwing: SyncError.timeout) }
        }
    }

    private func armTimeout(_ once: Once, _ fail: @escaping () -> Void) {
        queue.asyncAfter(deadline: deadline) { [connection] in
            once.run {
                connection.cancel()
                fail()
            }
        }
    }
}

/// Guarantees a continuation is resumed exactly once, whichever callback fires first.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ block: () -> Void) {
        lock.lock()
        if done { lock.unlock(); return }
        done = true
        lock.unlock()
        block()
    }
}
