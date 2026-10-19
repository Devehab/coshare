import Foundation

enum MessageType: String, Codable {
    case clip        // "here is something I just copied"
    case ack
    case pullLatest  // "what is the newest clip you know about?"
    case latest      // reply to pullLatest, carries a clip
    case nothing     // reply to pullLatest when history is empty
    case hello       // direct contact without Bonjour (e.g. on a phone's hotspot); carries port + groups
}

struct ClipMeta: Codable {
    let id: UUID
    let kind: ClipKind
    let uti: String?
    let hash: String
    let createdAt: Date
    /// Device where the clip was originally copied (a pull reply may come from another device).
    var origin: String?
}

struct WireHeader: Codable {
    let type: MessageType
    let senderID: String
    let senderName: String
    let platform: DevicePlatform
    var clip: ClipMeta?
    /// hello only: the sender's fixed listening port and the groups it is in.
    var listenPort: UInt16?
    var groups: [AdvertisedGroup]?
}

/// One request or reply. On the wire:
///   [UInt32 sealedLength][ChaChaPoly( [UInt32 headerLength][header JSON][payload] )]
struct WireMessage {
    var header: WireHeader
    var payload: Data

    static let maxFrameBytes = 64 * 1024 * 1024

    init(header: WireHeader, payload: Data = Data()) {
        self.header = header
        self.payload = payload
    }

    init(sealed: Data, using key: GroupKey) throws {
        let plain = try key.open(sealed)
        guard plain.count >= 4 else { throw SyncError.badMessage }
        let headerLength = Int(plain.readUInt32(at: 0))
        guard headerLength > 0, plain.count >= 4 + headerLength else { throw SyncError.badMessage }
        let start = plain.startIndex + 4
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        header = try decoder.decode(WireHeader.self, from: plain.subdata(in: start..<(start + headerLength)))
        payload = plain.subdata(in: (start + headerLength)..<plain.endIndex)
    }

    /// Encrypted, length-prefixed frame ready to write to a socket.
    func frame(using key: GroupKey) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let headerData = try encoder.encode(header)
        var plain = Data(capacity: 4 + headerData.count + payload.count)
        plain.appendUInt32(UInt32(headerData.count))
        plain.append(headerData)
        plain.append(payload)
        let sealed = try key.seal(plain)
        guard sealed.count <= Self.maxFrameBytes else { throw SyncError.frameTooLarge }
        var frame = Data(capacity: 4 + sealed.count)
        frame.appendUInt32(UInt32(sealed.count))
        frame.append(sealed)
        return frame
    }
}

enum SyncError: LocalizedError {
    case timeout
    case connectionClosed
    case badMessage
    case frameTooLarge
    case notReady

    var errorDescription: String? {
        switch self {
        case .timeout: return "انتهت المهلة"
        case .connectionClosed: return "انقطع الاتصال"
        case .badMessage: return "رسالة غير صالحة"
        case .frameTooLarge: return "الملف أكبر من الحد المسموح"
        case .notReady: return "الشبكة غير جاهزة بعد"
        }
    }
}

extension Data {
    mutating func appendUInt32(_ value: UInt32) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }

    func readUInt32(at offset: Int) -> UInt32 {
        let i = startIndex + offset
        return UInt32(self[i]) << 24 | UInt32(self[i + 1]) << 16 | UInt32(self[i + 2]) << 8 | UInt32(self[i + 3])
    }
}
