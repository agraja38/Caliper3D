import Foundation
import Security

/// In-memory Security identity, never Codable. Only the Keychain repository persists private material.
public struct LocalTLSIdentity {
    public let identity: SecIdentity
    public let certificate: SecCertificate
    public let fingerprint: String
    init(material: Data) throws {
        guard material.count <= 32_768 else { throw PairingError.invalidIdentity }
        let stored = try JSONDecoder().decode(IdentityMaterial.self, from: material)
        guard stored.version == 1,
              let certificate = SecCertificateCreateWithData(nil, stored.certificate as CFData),
              let key = SecKeyCreateWithData(stored.privateKey as CFData, [
                kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
                kSecAttrKeyClass: kSecAttrKeyClassPrivate,
                kSecAttrKeySizeInBits: 256
              ] as CFDictionary, nil),
              let identity = SecIdentityCreate(nil, certificate, key) else { throw PairingError.invalidIdentity }
        self.identity = identity; self.certificate = certificate
        fingerprint = TransferPolicy.digest(stored.certificate)
    }
}
private struct IdentityMaterial: Codable {
    var version = 1
    let privateKey: Data
    let certificate: Data
}
public actor KeychainIdentityRepository {
    private let vault: KeychainVault
    public init(vault: KeychainVault = KeychainVault()) { self.vault = vault }
    /// Instantiate Security references at the caller's isolation boundary.
    /// The returned bytes include private material: never log, export or write them to files.
    func material() throws -> Data {
        if let data = try vault.read(account: "tls-identity") { _ = try LocalTLSIdentity(material: data); return data }
        let data = try IdentityCertificate.createMaterial()
        _ = try LocalTLSIdentity(material: data)
        try vault.write(data, account: "tls-identity")
        return data
    }
    @MainActor public static func load(from repository: KeychainIdentityRepository) async throws -> LocalTLSIdentity {
        try LocalTLSIdentity(material: await repository.material())
    }
}

/// Minimal fixed-schema X.509 DER encoding, using Security for EC keys and ECDSA SHA-256 signing.
/// This is certificate serialization, not a custom cryptographic algorithm or trust evaluator.
enum IdentityCertificate {
    static func createMaterial(now: Date = Date()) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeySizeInBits: 256] as CFDictionary, &error),
              let publicKey = SecKeyCopyPublicKey(key),
              let point = SecKeyCopyExternalRepresentation(publicKey, &error) as Data?,
              let privateData = SecKeyCopyExternalRepresentation(key, &error) as Data? else { throw PairingError.invalidIdentity }
        let algorithm = sequence(oid([0x2a,0x86,0x48,0xce,0x3d,0x04,0x03,0x02])) // ecdsa-with-SHA256
        let commonName = sequence(tag(0x31, sequence(oid([0x55,0x04,0x03]) + tag(0x0c, Data(UUID().uuidString.utf8)))))
        let publicInfo = sequence(sequence(oid([0x2a,0x86,0x48,0xce,0x3d,0x02,0x01]) + oid([0x2a,0x86,0x48,0xce,0x3d,0x03,0x01,0x07])) + tag(0x03, Data([0]) + point))
        var serial = Data(count: 16)
        let status = serial.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard status == errSecSuccess else { throw PairingError.keychain(status) }
        serial[0] = (serial[0] & 0x7f) | 1
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyyMMddHHmmss'Z'"
        func time(_ date: Date) -> Data {
            let value = formatter.string(from: date)
            if let year = Int(value.prefix(4)), (1950...2049).contains(year) { return tag(0x17, Data(value.dropFirst(2).utf8)) }
            return tag(0x18, Data(value.utf8))
        }
        let validity = sequence(time(now.addingTimeInterval(-86400)) + time(now.addingTimeInterval(10 * 365 * 86400)))
        let basic = sequence(oid([0x55,0x1d,0x13]) + tag(0x01, Data([0xff])) + tag(0x04, sequence(Data())))
        let usage = sequence(oid([0x55,0x1d,0x0f]) + tag(0x01, Data([0xff])) + tag(0x04, tag(0x03, Data([7,0x80]))))
        let extended = sequence(oid([0x55,0x1d,0x25]) + tag(0x04, sequence(oid([0x2b,0x06,0x01,0x05,0x05,0x07,0x03,0x01]) + oid([0x2b,0x06,0x01,0x05,0x05,0x07,0x03,0x02]))))
        let tbs = sequence(tag(0xa0, tag(0x02, Data([2]))) + tag(0x02, serial) + algorithm + commonName + validity + commonName + publicInfo + tag(0xa3, sequence(basic + usage + extended)))
        guard let signature = SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, tbs as CFData, &error) as Data? else { throw PairingError.invalidIdentity }
        let certificate = sequence(tbs + algorithm + tag(0x03, Data([0]) + signature))
        return try JSONEncoder().encode(IdentityMaterial(privateKey: privateData, certificate: certificate))
    }
    private static func sequence(_ data: Data) -> Data { tag(0x30, data) }
    private static func oid(_ bytes: [UInt8]) -> Data { tag(0x06, Data(bytes)) }
    private static func tag(_ byte: UInt8, _ data: Data) -> Data {
        var length = Data()
        if data.count < 128 { length.append(UInt8(data.count)) }
        else {
            var count = data.count; var bytes: [UInt8] = []
            while count > 0 { bytes.insert(UInt8(count & 255), at: 0); count >>= 8 }
            length.append(0x80 | UInt8(bytes.count)); length.append(contentsOf: bytes)
        }
        return Data([byte]) + length + data
    }
}
