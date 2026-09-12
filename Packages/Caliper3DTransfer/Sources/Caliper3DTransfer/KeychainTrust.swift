import Foundation
import Security

/// App-scoped, non-synchronizing Keychain storage. No filesystem/UserDefaults fallback.
public struct KeychainVault: Sendable {
    private let service: String
    public init(service: String = "org.caliper3d.local-transfer.v1") { self.service = service }
    public func read(account: String) throws -> Data? {
        var query = base(account)
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, data.count <= 1_048_576 else { throw PairingError.keychain(status) }
        return data
    }
    public func write(_ data: Data, account: String) throws {
        guard data.count <= 1_048_576 else { throw PairingError.invalidMessage }
        let query = base(account)
        let changes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let updated = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if updated == errSecItemNotFound {
            var add = query; changes.forEach { add[$0.key] = $0.value }
            let status = SecItemAdd(add as CFDictionary, nil)
            guard status == errSecSuccess else { throw PairingError.keychain(status) }
        } else if updated != errSecSuccess { throw PairingError.keychain(updated) }
    }
    public func remove(account: String) throws {
        let status = SecItemDelete(base(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw PairingError.keychain(status) }
    }
    private func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false,
         kSecUseDataProtectionKeychain as String: true]
    }
}

public struct TrustedPeer: Codable, Equatable, Identifiable, Sendable {
    public let fingerprint: String
    public let name: String
    public let pairedAt: Date
    public var id: String { fingerprint }
}
/// Pure persisted trust model; only a completed pairing can add a peer.
public struct TrustRecords: Codable, Sendable {
    private var schema = 1
    public private(set) var peers: [TrustedPeer] = []
    public init() {}
    public mutating func approve(_ session: PairingSession, name: String, now: Date = Date()) throws {
        guard session.state == .approved, TransferPolicy.validText(name, maximum: 256) else { throw PairingError.rejected }
        let peer = TrustedPeer(fingerprint: session.tlsPeerFingerprint, name: name, pairedAt: now)
        peers.removeAll { $0.fingerprint == peer.fingerprint }
        guard peers.count < 100 else { throw PairingError.invalidMessage }
        peers.append(peer)
    }
    public func requirePinned(expected: String, presented: String) throws {
        try validate()
        guard expected == presented, peers.contains(where: { $0.fingerprint == expected }) else { throw PairingError.mismatch }
    }
    public mutating func forget(_ fingerprint: String) { peers.removeAll { $0.fingerprint == fingerprint } }
    public func validate() throws {
        guard schema == 1, peers.count <= 100, Set(peers.map(\.fingerprint)).count == peers.count,
              peers.allSatisfy({ TransferPolicy.isSHA256($0.fingerprint) && TransferPolicy.validText($0.name, maximum: 256) }) else { throw PairingError.invalidIdentity }
    }
}
public actor KeychainTrustRepository {
    private let vault: KeychainVault
    public init(vault: KeychainVault = KeychainVault()) { self.vault = vault }
    public func records() throws -> TrustRecords {
        guard let data = try vault.read(account: "trusted-peers") else { return TrustRecords() }
        let result = try JSONDecoder().decode(TrustRecords.self, from: data)
        try result.validate(); return result
    }
    public func approve(_ session: PairingSession, name: String) throws {
        var trust = try records(); try trust.approve(session, name: name)
        try vault.write(JSONEncoder().encode(trust), account: "trusted-peers")
    }
    public func forget(_ fingerprint: String) throws {
        var trust = try records(); trust.forget(fingerprint)
        try vault.write(JSONEncoder().encode(trust), account: "trusted-peers")
    }
}
