import Foundation

public enum WireError: Error, Equatable, LocalizedError {
    case invalidFrame, oversizedFrame, truncatedFrame, malformedMessage, unsupportedVersion(Int)
    case invalidManifest, unsafePath, invalidSequence, integrityMismatch, cancelled, timedOut
    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion: "The other device uses an unsupported transfer protocol. Update both apps."
        case .unsafePath, .invalidManifest: "The capture file list is invalid or exceeds transfer limits."
        case .integrityMismatch: "A capture file did not pass verification. Reconnect to retry."
        case .cancelled: "Transfer cancelled. The original capture is unchanged."
        case .timedOut: "Transfer interrupted. Reconnect to continue from verified files."
        default: "The other device sent an invalid transfer message. The connection must be closed."
        }
    }
}

/// Stable JSON envelope. Payload schemas are explicit structs, never synthesized enum layouts.
public struct ControlMessage: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case hello, helloResponse, pairingConfirmation, pairingRejected
        case transferOffer, transferAccepted, transferRejected
        case fileBegin, fileComplete, transferComplete, cancel, error, ping, pong
    }
    public let version: Int
    public let type: Kind
    public let payload: Payload
    public init(type: Kind, payload: Payload) {
        version = TransferPolicy.protocolVersion; self.type = type; self.payload = payload
    }
    public enum Payload: Equatable, Sendable {
        case hello(PeerHello), confirmation(PairingConfirmation), manifest(TransferManifest)
        case accepted(TransferAcceptance), file(FileReference), completion(TransferCompletion)
        case reason(TransferReason), empty
    }
    private enum CodingKeys: String, CodingKey { case version, type, payload }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        guard version == TransferPolicy.protocolVersion else { throw WireError.unsupportedVersion(version) }
        type = try c.decode(Kind.self, forKey: .type)
        switch type {
        case .hello, .helloResponse: payload = .hello(try c.decode(PeerHello.self, forKey: .payload))
        case .pairingConfirmation: payload = .confirmation(try c.decode(PairingConfirmation.self, forKey: .payload))
        case .transferOffer: payload = .manifest(try c.decode(TransferManifest.self, forKey: .payload))
        case .transferAccepted: payload = .accepted(try c.decode(TransferAcceptance.self, forKey: .payload))
        case .fileBegin, .fileComplete: payload = .file(try c.decode(FileReference.self, forKey: .payload))
        case .transferComplete: payload = .completion(try c.decode(TransferCompletion.self, forKey: .payload))
        case .pairingRejected, .transferRejected, .cancel, .error: payload = .reason(try c.decode(TransferReason.self, forKey: .payload))
        case .ping, .pong:
            guard !c.contains(.payload) else { throw WireError.malformedMessage }
            payload = .empty
        }
        try validate()
    }
    public func encode(to encoder: Encoder) throws {
        try validate()
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version); try c.encode(type, forKey: .type)
        switch payload {
        case .hello(let p): try c.encode(p, forKey: .payload)
        case .confirmation(let p): try c.encode(p, forKey: .payload)
        case .manifest(let p): try c.encode(p, forKey: .payload)
        case .accepted(let p): try c.encode(p, forKey: .payload)
        case .file(let p): try c.encode(p, forKey: .payload)
        case .completion(let p): try c.encode(p, forKey: .payload)
        case .reason(let p): try c.encode(p, forKey: .payload)
        case .empty: break
        }
    }
    public func validate() throws {
        guard version == TransferPolicy.protocolVersion else { throw WireError.unsupportedVersion(version) }
        switch (type, payload) {
        case (.hello, .hello(let p)), (.helloResponse, .hello(let p)):
            guard TransferPolicy.validText(p.name, maximum: 256), TransferPolicy.validText(p.operatingSystem, maximum: 128),
                  TransferPolicy.isSHA256(p.identityFingerprint), TransferPolicy.isSHA256(p.nonce) else { throw WireError.malformedMessage }
        case (.pairingConfirmation, .confirmation(let p)):
            guard TransferPolicy.isSHA256(p.transcriptDigest) else { throw WireError.malformedMessage }
        case (.transferOffer, .manifest(let p)): try p.validate()
        case (.transferAccepted, .accepted(let p)):
            guard TransferPolicy.isSHA256(p.manifestDigest), p.verifiedFileIndices.count <= TransferPolicy.maximumFiles,
                  p.verifiedFileIndices.allSatisfy({ $0 >= 0 && $0 < TransferPolicy.maximumFiles }),
                  Set(p.verifiedFileIndices).count == p.verifiedFileIndices.count else { throw WireError.malformedMessage }
        case (.fileBegin, .file(let p)), (.fileComplete, .file(let p)):
            guard p.index >= 0, p.index < TransferPolicy.maximumFiles else { throw WireError.malformedMessage }
        case (.transferComplete, .completion(let p)):
            guard TransferPolicy.isSHA256(p.manifestDigest) else { throw WireError.malformedMessage }
        case (.pairingRejected, .reason(let p)), (.transferRejected, .reason(let p)), (.cancel, .reason(let p)), (.error, .reason(let p)):
            guard TransferPolicy.validText(p.code, maximum: 64) else { throw WireError.malformedMessage }
        case (.ping, .empty), (.pong, .empty): break
        default: throw WireError.malformedMessage
        }
    }
}
public struct PeerHello: Codable, Equatable, Sendable {
    public let name: String
    public let operatingSystem: String
    public let objectCaptureSupported: Bool?
    public let identityFingerprint: String
    /// 32 cryptographically random bytes encoded as 64 lowercase hex digits; not a secret.
    public let nonce: String
    public init(name: String, operatingSystem: String, objectCaptureSupported: Bool?, identityFingerprint: String, nonce: String) {
        self.name = name; self.operatingSystem = operatingSystem; self.objectCaptureSupported = objectCaptureSupported
        self.identityFingerprint = identityFingerprint; self.nonce = nonce
    }
}
public struct PairingConfirmation: Codable, Equatable, Sendable {
    public let transcriptDigest: String
    public init(transcriptDigest: String) { self.transcriptDigest = transcriptDigest }
}
public struct TransferAcceptance: Codable, Equatable, Sendable {
    public let transferID: UUID
    public let manifestDigest: String
    public let verifiedFileIndices: [Int]
    public init(transferID: UUID, manifestDigest: String, verifiedFileIndices: [Int]) {
        self.transferID = transferID; self.manifestDigest = manifestDigest; self.verifiedFileIndices = verifiedFileIndices
    }
}
public struct FileReference: Codable, Equatable, Sendable {
    public let transferID: UUID
    public let index: Int
    public init(transferID: UUID, index: Int) { self.transferID = transferID; self.index = index }
}
public struct TransferCompletion: Codable, Equatable, Sendable {
    public let transferID: UUID
    public let projectID: UUID
    public let manifestDigest: String
    public init(transferID: UUID, projectID: UUID, manifestDigest: String) {
        self.transferID = transferID; self.projectID = projectID; self.manifestDigest = manifestDigest
    }
}
public struct TransferReason: Codable, Equatable, Sendable {
    public let transferID: UUID?
    public let code: String
    public init(transferID: UUID? = nil, code: String) { self.transferID = transferID; self.code = code }
}

public enum WireFrame: Equatable, Sendable {
    case control(ControlMessage), binary(Data)
    public func encoded() throws -> Data {
        let kind: UInt8
        let payload: Data
        switch self {
        case .control(let message):
            kind = 1
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            payload = try encoder.encode(message)
            guard payload.count <= TransferPolicy.maximumControlBytes else { throw WireError.oversizedFrame }
        case .binary(let bytes):
            kind = 2; payload = bytes
            guard !bytes.isEmpty, bytes.count <= TransferPolicy.chunkBytes else { throw WireError.invalidFrame }
        }
        let count = UInt32(payload.count)
        var result = Data([kind, UInt8((count >> 24) & 255), UInt8((count >> 16) & 255), UInt8((count >> 8) & 255), UInt8(count & 255)])
        result.append(payload); return result
    }
}

/// Feed at most receiveBytes per call. Memory is bounded by one control frame plus one receive.
/// Any decoding failure poisons the decoder; close the connection rather than resynchronizing.
public struct FrameDecoder: Sendable {
    private var buffer = Data()
    private var failed = false
    public init() {}
    public mutating func append(_ data: Data) throws -> [WireFrame] {
        guard !failed else { throw WireError.invalidFrame }
        do {
            guard data.count <= TransferPolicy.receiveBytes else { throw WireError.oversizedFrame }
            buffer.append(data)
            var frames: [WireFrame] = []
            var offset = 0
            while buffer.count - offset >= 5 {
                let header = Array(buffer.dropFirst(offset).prefix(5))
                guard header[0] == 1 || header[0] == 2 else { throw WireError.invalidFrame }
                let length = header[1...4].reduce(0) { ($0 << 8) | Int($1) }
                guard length > 0 else { throw WireError.invalidFrame }
                let limit = header[0] == 1 ? TransferPolicy.maximumControlBytes : TransferPolicy.chunkBytes
                guard length <= limit else { throw WireError.oversizedFrame }
                guard buffer.count - offset >= 5 + length else { break }
                let body = Data(buffer.dropFirst(offset + 5).prefix(length))
                if header[0] == 1 {
                    do { frames.append(.control(try JSONDecoder().decode(ControlMessage.self, from: body))) }
                    catch let error as WireError { throw error }
                    catch { throw WireError.malformedMessage }
                } else { frames.append(.binary(body)) }
                offset += 5 + length
            }
            if offset > 0 { buffer = Data(buffer.dropFirst(offset)) }
            return frames
        } catch { failed = true; buffer.removeAll(); throw error }
    }
    public mutating func finish() throws {
        guard !failed, buffer.isEmpty else { failed = true; buffer.removeAll(); throw WireError.truncatedFrame }
    }
}
