import Foundation
import UniformTypeIdentifiers

/// Last 24 hours of clips (sent and received). Older items are deleted automatically.
@MainActor
final class HistoryStore: ObservableObject {
    static let retention: TimeInterval = 24 * 60 * 60
    static let maxItems = 300

    @Published private(set) var items: [HistoryItem] = []

    private let indexURL: URL
    private let blobsURL: URL
    private var saveScheduled = false

    init(directory: URL) {
        indexURL = directory.appendingPathComponent("history.json")
        blobsURL = directory.appendingPathComponent("blobs", isDirectory: true)
        try? FileManager.default.createDirectory(at: blobsURL, withIntermediateDirectories: true)
        items = Storage.read([HistoryItem].self, from: indexURL) ?? []
        purge()
        removeOrphanBlobs()
    }

    @discardableResult
    func add(_ content: ClipContent, hash: String, deviceName: String, direction: ClipDirection, date: Date = Date()) -> HistoryItem {
        if let index = items.firstIndex(where: { $0.hash == hash }) {
            removeBlob(of: items.remove(at: index))
        }
        let id = UUID()
        var item = HistoryItem(id: id, kind: content.kind, text: nil, blobName: nil, uti: content.uti, hash: hash,
                               byteCount: content.payload.count, deviceName: deviceName, direction: direction,
                               date: date, deliveredTo: nil)
        switch content {
        case .text(let string):
            item.text = string
        case .image(let data, let uti):
            let ext = UTType(uti)?.preferredFilenameExtension ?? "img"
            let name = "\(id.uuidString).\(ext)"
            try? data.write(to: blobsURL.appendingPathComponent(name), options: .atomic)
            item.blobName = name
        }
        items.insert(item, at: 0)
        while items.count > Self.maxItems { removeBlob(of: items.removeLast()) }
        scheduleSave()
        return item
    }

    func setDelivered(_ id: UUID, count: Int) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].deliveredTo = count
        scheduleSave()
    }

    func content(of item: HistoryItem) -> ClipContent? {
        switch item.kind {
        case .text:
            return item.text.map(ClipContent.text)
        case .image:
            guard let url = imageURL(for: item), let data = try? Data(contentsOf: url) else { return nil }
            return .image(data, uti: item.uti ?? UTType.png.identifier)
        }
    }

    func imageURL(for item: HistoryItem) -> URL? {
        item.blobName.map { blobsURL.appendingPathComponent($0) }
    }

    func delete(_ item: HistoryItem) {
        items.removeAll { $0.id == item.id }
        removeBlob(of: item)
        scheduleSave()
    }

    func clear() {
        items.forEach(removeBlob)
        items.removeAll()
        scheduleSave()
    }

    /// Drops everything older than 24 hours.
    func purge() {
        let cutoff = Date().addingTimeInterval(-Self.retention)
        let expired = items.filter { $0.date < cutoff }
        guard !expired.isEmpty else { return }
        expired.forEach(removeBlob)
        items.removeAll { $0.date < cutoff }
        scheduleSave()
    }

    private func removeBlob(of item: HistoryItem) {
        guard let url = imageURL(for: item) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func removeOrphanBlobs() {
        let referenced = Set(items.compactMap(\.blobName))
        let files = (try? FileManager.default.contentsOfDirectory(atPath: blobsURL.path)) ?? []
        for file in files where !referenced.contains(file) {
            try? FileManager.default.removeItem(at: blobsURL.appendingPathComponent(file))
        }
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.saveScheduled = false
            Storage.write(self.items, to: self.indexURL)
        }
    }
}

/// Human-readable event log, also limited to the last 24 hours — enough to see that sync is working.
@MainActor
final class ActivityLog: ObservableObject {
    struct Entry: Codable, Identifiable {
        var id = UUID()
        let date: Date
        let text: String
        let isError: Bool
    }

    @Published private(set) var entries: [Entry] = []

    private let url: URL
    private var saveScheduled = false

    init(directory: URL) {
        url = directory.appendingPathComponent("activity.json")
        entries = Storage.read([Entry].self, from: url) ?? []
        purge()
    }

    func add(_ text: String, isError: Bool = false) {
        entries.insert(Entry(date: Date(), text: text, isError: isError), at: 0)
        if entries.count > 1000 { entries.removeLast(entries.count - 1000) }
        if AppEnvironment.verbose { print("[CoShare] \(isError ? "⚠️ " : "")\(text)") }
        scheduleSave()
    }

    func purge() {
        let cutoff = Date().addingTimeInterval(-HistoryStore.retention)
        guard entries.contains(where: { $0.date < cutoff }) else { return }
        entries.removeAll { $0.date < cutoff }
        scheduleSave()
    }

    func clear() {
        entries.removeAll()
        scheduleSave()
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.saveScheduled = false
            Storage.write(self.entries, to: self.url)
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    let deviceID: String
    let maxImageBytes = 40 * 1024 * 1024

    @Published var deviceName: String { didSet { defaults.set(deviceName, forKey: Keys.deviceName) } }
    /// Groups this device belongs to; saved, so it rejoins them automatically after a restart.
    @Published var groups: [GroupMembership] {
        didSet { defaults.set(try? JSONEncoder().encode(groups), forKey: Keys.groups) }
    }
    @Published var syncImages: Bool { didSet { defaults.set(syncImages, forKey: Keys.syncImages) } }
    @Published var paused: Bool { didSet { defaults.set(paused, forKey: Keys.paused) } }
    @Published var keepAlive: Bool { didSet { defaults.set(keepAlive, forKey: Keys.keepAlive) } }
    @Published var skipConcealed: Bool { didSet { defaults.set(skipConcealed, forKey: Keys.skipConcealed) } }
    /// Scheduled quiet hours: completely off the network.
    @Published var quietEnabled: Bool { didSet { defaults.set(quietEnabled, forKey: Keys.quietEnabled) } }
    @Published var quietSchedule: QuietSchedule {
        didSet { defaults.set(try? JSONEncoder().encode(quietSchedule), forKey: Keys.quietSchedule) }
    }
    /// Start of the quiet window the person chose to skip with "resume today".
    @Published var resumedWindowStart: Date? { didSet { defaults.set(resumedWindowStart, forKey: Keys.resumedWindowStart) } }

    let defaults: UserDefaults

    private enum Keys {
        static let deviceID = "deviceID"
        static let deviceName = "deviceName"
        static let groups = "groups"
        static let syncImages = "syncImages"
        static let paused = "paused"
        static let keepAlive = "keepAlive"
        static let skipConcealed = "skipConcealed"
        static let quietEnabled = "quietEnabled"
        static let quietSchedule = "quietSchedule"
        static let resumedWindowStart = "resumedWindowStart"
    }

    init(defaults: UserDefaults, defaultName: String) {
        self.defaults = defaults
        defaults.register(defaults: [Keys.syncImages: true, Keys.keepAlive: true, Keys.skipConcealed: true])
        if let id = defaults.string(forKey: Keys.deviceID) {
            deviceID = id
        } else {
            deviceID = UUID().uuidString
            defaults.set(deviceID, forKey: Keys.deviceID)
        }
        _deviceName = Published(initialValue: defaults.string(forKey: Keys.deviceName) ?? defaultName)
        // A fresh install is in no group, so it shares nothing until the person creates or joins one.
        let saved = defaults.data(forKey: Keys.groups).flatMap { try? JSONDecoder().decode([GroupMembership].self, from: $0) }
        _groups = Published(initialValue: saved ?? [])
        defaults.removeObject(forKey: "passphrase") // pairing code from the previous version
        _syncImages = Published(initialValue: defaults.bool(forKey: Keys.syncImages))
        _paused = Published(initialValue: defaults.bool(forKey: Keys.paused))
        _keepAlive = Published(initialValue: defaults.bool(forKey: Keys.keepAlive))
        _skipConcealed = Published(initialValue: defaults.bool(forKey: Keys.skipConcealed))
        _quietEnabled = Published(initialValue: defaults.bool(forKey: Keys.quietEnabled))
        _quietSchedule = Published(initialValue: defaults.data(forKey: Keys.quietSchedule)
            .flatMap { try? JSONDecoder().decode(QuietSchedule.self, from: $0) } ?? .default)
        _resumedWindowStart = Published(initialValue: defaults.object(forKey: Keys.resumedWindowStart) as? Date)
    }
}
