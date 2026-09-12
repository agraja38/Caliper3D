import Foundation
import CryptoKit
import Security

public enum PairingError: Error, Equatable, LocalizedError {
    case invalidIdentity, invalidMessage, mismatch, expired, rejected, keychain(OSStatus)
    public var errorDescription: String? {
        switch self {
        case .expired: "Pairing expired. Start again on both devices."
        case .rejected: "Pairing was declined. No new device has been trusted."
        case .keychain: "Caliper3D could not access its protected device identity. Unlock the device and try again."
        default: "Device verification failed. Close this connection and pair again."
        }
    }
}

/// Short authentication string over a TLS exporter, with commit/reveal to prevent choosing a
/// nonce after seeing the other party's nonce. No encryption or key exchange is implemented here.
/// The adapter must supply the actual live TLS exporter and verified TLS peer fingerprint.
public struct PairingSession: Sendable {
    public enum Role: String, Sendable { case phone, mac }
    public enum State: Equatable, Sendable { case awaitingCommitment, awaitingReveal, awaitingConfirmation, approved, rejected }
    public private(set) var state: State = .awaitingCommitment
    public private(set) var verificationCode: String?
    public let tlsPeerFingerprint: String
    private let role: Role
    private let exporter: SymmetricKey
    private let localNonce: Data
    private let context: Data
    private let deadline: Date
    private var peerCommitment: String?
    private var confirmationDigest: String?
    private var localConfirmed = false
    private var peerConfirmed = false

    public init(role: Role, phoneFingerprint: String, macFingerprint: String,
                tlsPeerFingerprint: String, tlsExporter: Data, now: Date = Date()) throws {
        var nonce = Data(count: 32)
        let status = nonce.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard status == errSecSuccess else { throw PairingError.keychain(status) }
        try self.init(role: role, phoneFingerprint: phoneFingerprint, macFingerprint: macFingerprint,
                      tlsPeerFingerprint: tlsPeerFingerprint, tlsExporter: tlsExporter, nonce: nonce, now: now)
    }
    // Deterministic nonce injection is internal to the package for tests only.
    init(role: Role, phoneFingerprint: String, macFingerprint: String, tlsPeerFingerprint: String,
         tlsExporter: Data, nonce: Data, now: Date) throws {
        guard TransferPolicy.isSHA256(phoneFingerprint), TransferPolicy.isSHA256(macFingerprint),
              phoneFingerprint != macFingerprint,
              tlsPeerFingerprint == (role == .phone ? macFingerprint : phoneFingerprint),
              tlsExporter.count == 32, nonce.count == 32 else { throw PairingError.invalidIdentity }
        self.role = role; self.tlsPeerFingerprint = tlsPeerFingerprint
        exporter = SymmetricKey(data: tlsExporter); localNonce = nonce
        context = Data(("Caliper3D pairing v1\n" + phoneFingerprint + "\n" + macFingerprint + "\n").utf8)
        deadline = now.addingTimeInterval(120)
    }
    public var commitment: String { Self.commit(localNonce, role: role, context: context) }
    public mutating func receiveCommitment(_ value: String, now: Date = Date()) throws {
        try checkDeadline(now)
        guard state == .awaitingCommitment, TransferPolicy.isSHA256(value), value != commitment else { try fail(.invalidMessage) }
        peerCommitment = value; state = .awaitingReveal
    }
    public mutating func reveal(now: Date = Date()) throws -> String {
        try checkDeadline(now)
        guard state == .awaitingReveal else { try fail(.invalidMessage) }
        return TransferPolicy.hex(localNonce)
    }
    public mutating func receiveReveal(_ value: String, now: Date = Date()) throws {
        try checkDeadline(now)
        guard state == .awaitingReveal, let nonce = Self.unhex(value),
              peerCommitment == Self.commit(nonce, role: role == .phone ? .mac : .phone, context: context) else { try fail(.mismatch) }
        let phoneNonce = role == .phone ? localNonce : nonce
        let macNonce = role == .mac ? localNonce : nonce
        let transcript = context + phoneNonce + macNonce
        let authentication = Data(HMAC<SHA256>.authenticationCode(for: Data("code\n".utf8) + transcript, using: exporter))
        let numeric = authentication.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } % 1_000_000
        let digits = String(format: "%06u", numeric)
        verificationCode = String(digits.prefix(3)) + " " + String(digits.suffix(3))
        confirmationDigest = TransferPolicy.hex(HMAC<SHA256>.authenticationCode(for: Data("confirmation\n".utf8) + transcript, using: exporter))
        state = .awaitingConfirmation
    }
    public mutating func confirmLocally(now: Date = Date()) throws -> String {
        try checkDeadline(now)
        guard state == .awaitingConfirmation, let confirmationDigest, !localConfirmed else { try fail(.invalidMessage) }
        localConfirmed = true
        if peerConfirmed { state = .approved }
        return confirmationDigest
    }
    public mutating func receiveConfirmation(_ value: String, now: Date = Date()) throws {
        try checkDeadline(now)
        guard state == .awaitingConfirmation, let confirmationDigest, value == confirmationDigest, !peerConfirmed else { try fail(.mismatch) }
        peerConfirmed = true
        if localConfirmed { state = .approved }
    }
    public mutating func reject() { state = .rejected; verificationCode = nil; confirmationDigest = nil }
    private mutating func checkDeadline(_ now: Date) throws {
        guard now < deadline else { try fail(.expired) }
        guard state != .rejected else { throw PairingError.rejected }
    }
    private mutating func fail(_ error: PairingError) throws -> Never { reject(); throw error }
    private static func commit(_ nonce: Data, role: Role, context: Data) -> String {
        TransferPolicy.digest(context + Data((role.rawValue + "\n").utf8) + nonce)
    }
    private static func unhex(_ value: String) -> Data? {
        guard TransferPolicy.isSHA256(value) else { return nil }
        let bytes = Array(value.utf8); var result = Data()
        for index in stride(from: 0, to: bytes.count, by: 2) {
            guard let byte = UInt8(String(decoding: bytes[index...index+1], as: UTF8.self), radix: 16) else { return nil }
            result.append(byte)
        }
        return result
    }
}
