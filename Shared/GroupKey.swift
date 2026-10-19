import Foundation
import CryptoKit
import CommonCrypto

/// Symmetric key of one group, derived from its password (salted with the group's ID, so the same
/// password in two groups gives two unrelated keys). All traffic is sealed with ChaCha20-Poly1305,
/// so other machines on the Wi-Fi can neither read clips nor inject them.
struct GroupKey: @unchecked Sendable {
    let key: SymmetricKey
    /// Short public fingerprint advertised over Bonjour. A device that wants to join checks the
    /// password it was given against it — without the group ever sending anything secret.
    let tag: String

    init(groupID: String, password: String) {
        key = SymmetricKey(data: Self.pbkdf2(password, salt: "CoShare.v2.group." + groupID))
        var hasher = SHA256()
        key.withUnsafeBytes { hasher.update(bufferPointer: $0) }
        hasher.update(data: Data("coshare-tag".utf8))
        tag = hasher.finalize().prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    func seal(_ plaintext: Data) throws -> Data {
        try ChaChaPoly.seal(plaintext, using: key).combined
    }

    func open(_ sealed: Data) throws -> Data {
        try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: sealed), using: key)
    }

    private static func pbkdf2(_ password: String, salt saltString: String) -> Data {
        let salt = Array(saltString.utf8)
        var derived = [UInt8](repeating: 0, count: 32)
        let status = CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            password, password.utf8.count,
            salt, salt.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
            120_000,
            &derived, derived.count
        )
        precondition(status == kCCSuccess, "PBKDF2 failed")
        return Data(derived)
    }
}
