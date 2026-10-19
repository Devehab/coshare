import Foundation
import CoreImage

/// A private group of devices: everyone who knows the group's password. A device can be in
/// several groups; whatever it copies goes to every group it belongs to.
struct GroupMembership: Codable, Identifiable, Hashable {
    /// Random and public — advertised on the network so others can find the group.
    let id: String
    var name: String
    /// Stays on the device (it only travels inside an invite link the person chooses to show).
    var password: String
    var joinedAt: Date

    static let minimumPasswordLength = 6

    static func newID() -> String {
        let alphabet = Array("0123456789abcdefghjkmnpqrstvwxyz")
        var bytes = [UInt8](repeating: 0, count: 12)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return String(bytes.map { alphabet[Int($0) % alphabet.count] })
    }
}

/// A group as another device advertises it (no secrets: the tag only lets a joiner check a password).
struct AdvertisedGroup: Codable, Hashable {
    let id: String
    let tag: String
    let name: String

    /// Bonjour TXT value, e.g. "k3x9…|a1b2c3d4|Ehab's devices".
    var txtValue: String { "\(id)|\(tag)|\(String(name.replacingOccurrences(of: "|", with: "/").prefix(48)))" }

    init(id: String, tag: String, name: String) {
        self.id = id
        self.tag = tag
        self.name = name
    }

    init?(txtValue: String) {
        let parts = txtValue.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        self.init(id: parts[0], tag: parts[1], name: parts[2])
    }
}

/// A joined group with its derived key, ready for the network layer.
struct GroupSecret: @unchecked Sendable {
    let membership: GroupMembership
    let key: GroupKey

    var id: String { membership.id }
    var advertised: AdvertisedGroup { AdvertisedGroup(id: membership.id, tag: key.tag, name: membership.name) }
}

/// A group seen on the network that this device hasn't joined yet.
struct NearbyGroup: Identifiable, Hashable {
    let group: AdvertisedGroup
    var memberNames: [String]
    var id: String { group.id + group.tag }
}

/// `coshare://join?g=<id>&n=<name>&p=<password>` — scanned with the phone camera, it opens CoShare and joins.
enum GroupInvite {
    static func url(for group: GroupMembership) -> URL {
        var components = URLComponents()
        components.scheme = "coshare"
        components.host = "join"
        components.queryItems = [
            URLQueryItem(name: "g", value: group.id),
            URLQueryItem(name: "n", value: group.name),
            URLQueryItem(name: "p", value: group.password),
        ]
        return components.url!
    }

    static func parse(_ url: URL) -> GroupMembership? {
        guard url.scheme == "coshare", url.host == "join",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let id = items.first(where: { $0.name == "g" })?.value, !id.isEmpty,
              let password = items.first(where: { $0.name == "p" })?.value, !password.isEmpty
        else { return nil }
        let name = items.first(where: { $0.name == "n" })?.value ?? "CoShare"
        return GroupMembership(id: id, name: name, password: password, joinedAt: Date())
    }

    static func qrImage(for url: URL, scale: CGFloat = 10) -> CGImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(url.absoluteString.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}

enum GroupError: LocalizedError {
    case wrongPassword
    case passwordTooShort
    case nameMissing

    var errorDescription: String? {
        switch self {
        case .wrongPassword: return "كلمة السر غير صحيحة"
        case .passwordTooShort: return "كلمة السر لازم تكون \(GroupMembership.minimumPasswordLength) أحرف على الأقل"
        case .nameMissing: return "اكتب اسم للمجموعة"
        }
    }
}
