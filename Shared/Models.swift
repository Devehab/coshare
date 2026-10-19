import Foundation
import CryptoKit
import UniformTypeIdentifiers

enum ClipKind: String, Codable {
    case text
    case image
}

enum ClipDirection: String, Codable {
    case sent
    case received
}

enum DevicePlatform: String, Codable {
    case mac
    case iphone
    case ipad
    case windows
    case linux
    case android
    /// A platform added after this build; decoding never fails because of it.
    case other

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = DevicePlatform(rawValue: raw) ?? .other
    }

    var symbolName: String {
        switch self {
        case .mac: return "laptopcomputer"
        case .iphone: return "iphone"
        case .ipad: return "ipad"
        case .windows: return "desktopcomputer"
        case .linux: return "terminal"
        case .android: return "candybarphone"
        case .other: return "questionmark.circle"
        }
    }
}

/// The clipboard payload that moves between devices.
enum ClipContent: Equatable {
    case text(String)
    case image(Data, uti: String)

    init?(kind: ClipKind, uti: String?, payload: Data) {
        switch kind {
        case .text:
            guard let string = String(data: payload, encoding: .utf8), !string.isEmpty else { return nil }
            self = .text(string)
        case .image:
            guard !payload.isEmpty else { return nil }
            self = .image(payload, uti: uti ?? UTType.png.identifier)
        }
    }

    var kind: ClipKind {
        if case .text = self { return .text }
        return .image
    }

    var payload: Data {
        switch self {
        case .text(let string): return Data(string.utf8)
        case .image(let data, _): return data
        }
    }

    var uti: String? {
        if case .image(_, let uti) = self { return uti }
        return nil
    }

    /// Content hash used to recognise the same clip across devices (and to break echo loops).
    var hash: String {
        var hasher = SHA256()
        hasher.update(data: Data(kind.rawValue.utf8))
        hasher.update(data: payload)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    var label: String { kind == .text ? "نص" : "صورة" }
}

struct HistoryItem: Codable, Identifiable, Equatable {
    let id: UUID
    let kind: ClipKind
    var text: String?
    var blobName: String?
    var uti: String?
    let hash: String
    let byteCount: Int
    let deviceName: String
    let direction: ClipDirection
    var date: Date
    var deliveredTo: Int?
}

/// Pulls a one-time code out of an SMS such as "Your code is 482 913" → "482913".
enum CodeExtractor {
    static func firstCode(in text: String) -> String? {
        let patterns = [#"(?<!\d)\d{3}[- ]\d{3}(?!\d)"#, #"(?<!\d)\d{4,8}(?!\d)"#]
        for pattern in patterns {
            if let range = text.range(of: pattern, options: .regularExpression) {
                // wholeNumberValue also converts Arabic-Indic digits (٤٨٢) to Western ones.
                return text[range].compactMap(\.wholeNumberValue).map(String.init).joined()
            }
        }
        return nil
    }
}

/// Per-process locations. COSHARE_PROFILE lets a second copy run side by side for testing.
struct AppEnvironment {
    let defaults: UserDefaults
    let dataDirectory: URL
    let profile: String?

    static let current: AppEnvironment = {
        let profile = ProcessInfo.processInfo.environment["COSHARE_PROFILE"].flatMap { $0.isEmpty ? nil : $0 }
        let defaults = profile.flatMap { UserDefaults(suiteName: "CoShare.\($0)") } ?? .standard
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent(profile.map { "CoShare-\($0)" } ?? "CoShare", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return AppEnvironment(defaults: defaults, dataDirectory: directory, profile: profile)
    }()

    static var verbose: Bool { ProcessInfo.processInfo.environment["COSHARE_VERBOSE"] != nil }

    // Test switches (see Tools/TestPeer): run without Bonjour, on another port, with extra hosts to greet.
    var noBonjour: Bool { ProcessInfo.processInfo.environment["COSHARE_NO_BONJOUR"] != nil }
    var portOverride: UInt16? { ProcessInfo.processInfo.environment["COSHARE_PORT"].flatMap { UInt16($0) } }
    var extraHosts: Set<String> {
        Set((ProcessInfo.processInfo.environment["COSHARE_HOSTS"] ?? "").split(separator: ",").map(String.init))
    }
}

enum Storage {
    private static let queue = DispatchQueue(label: "coshare.storage", qos: .utility)

    static func write<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        queue.async { try? data.write(to: url, options: .atomic) }
    }

    static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
