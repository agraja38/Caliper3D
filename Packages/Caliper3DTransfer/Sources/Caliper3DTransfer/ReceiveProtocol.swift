import Foundation

/// Socket-independent receiver ordering. The transport must close on any thrown protocol error.
/// Trust and disk finalization are local events; peer JSON cannot grant either capability.
public struct ReceiveProtocol: Sendable {
    public enum State: Equatable, Sendable {
        case awaitingHello, awaitingTrust, idle, offered, receiving, finalizing, completed, cancelled, interrupted, failed
    }
    public private(set) var state: State = .awaitingHello
    public private(set) var manifest: TransferManifest?
    public private(set) var verifiedIndices = Set<Int>()
    public private(set) var receivedBytes: Int64 = 0
    private var active: (index: Int, verifier: FileIntegrityVerifier)?
    private var peerFingerprint: String?
    public init() {}

    /// Called only after TLS peer proof, transcript verification, and both explicit confirmations
    /// (or pinned mutual authentication on a subsequent connection). Never from a wire message.
    public mutating func authorizePeer(tlsFingerprint: String) throws {
        guard state == .awaitingTrust, peerFingerprint == tlsFingerprint else { state = .failed; throw WireError.invalidSequence }
        state = .idle
    }
    public mutating func receive(_ frame: WireFrame) throws {
        do {
            guard ![.completed, .cancelled, .interrupted, .failed].contains(state) else { throw WireError.invalidSequence }
            switch frame {
            case .binary(let data):
                guard state == .receiving, var file = active, !data.isEmpty else { throw WireError.invalidSequence }
                try file.verifier.consume(data); active = file; receivedBytes += Int64(data.count)
            case .control(let message):
                try message.validate()
                switch (message.type, message.payload) {
                case (.hello, .hello(let hello)):
                    guard state == .awaitingHello else { throw WireError.invalidSequence }
                    peerFingerprint = hello.identityFingerprint; state = .awaitingTrust
                case (.transferOffer, .manifest(let offer)):
                    guard state == .idle else { throw WireError.invalidSequence }
                    _ = try offer.canonicalData(); manifest = offer; state = .offered
                case (.fileBegin, .file(let reference)):
                    guard state == .receiving, active == nil, let manifest,
                          reference.transferID == manifest.transferID, manifest.files.indices.contains(reference.index),
                          !verifiedIndices.contains(reference.index) else { throw WireError.invalidSequence }
                    active = (reference.index, try FileIntegrityVerifier(file: manifest.files[reference.index]))
                case (.fileComplete, .file(let reference)):
                    guard state == .receiving, var file = active, let manifest,
                          reference.transferID == manifest.transferID, reference.index == file.index else { throw WireError.invalidSequence }
                    try file.verifier.finish()
                    verifiedIndices.insert(file.index); active = nil
                    if verifiedIndices.count == manifest.files.count { state = .finalizing }
                case (.cancel, .reason(let reason)):
                    guard reason.transferID == manifest?.transferID else { throw WireError.invalidSequence }
                    active = nil; state = .cancelled
                case (.ping, .empty), (.pong, .empty):
                    guard state != .awaitingHello else { throw WireError.invalidSequence }
                default: throw WireError.invalidSequence
                }
            }
        } catch { active = nil; state = .failed; throw error }
    }
    /// The receiver must rehash disk files against this exact manifest before supplying indices.
    /// A saved journal alone is not proof. This method does not read or write files.
    public mutating func accept(reverifiedIndices: Set<Int> = []) throws -> TransferAcceptance {
        guard state == .offered, let manifest, reverifiedIndices.allSatisfy(manifest.files.indices.contains) else {
            state = .failed; throw WireError.invalidSequence
        }
        verifiedIndices = reverifiedIndices
        receivedBytes = reverifiedIndices.reduce(0) { $0 + manifest.files[$1].bytes }
        state = verifiedIndices.count == manifest.files.count ? .finalizing : .receiving
        return TransferAcceptance(transferID: manifest.transferID, manifestDigest: try manifest.digest(), verifiedFileIndices: verifiedIndices.sorted())
    }
    public mutating func decline() throws {
        guard state == .offered else { state = .failed; throw WireError.invalidSequence }
        manifest = nil; state = .idle
    }
    /// Only call after all verified bytes have been written and atomically committed by LocalProjectStore.
    public mutating func finalized(projectID: UUID) throws -> TransferCompletion {
        guard state == .finalizing, let manifest, active == nil, receivedBytes == manifest.totalBytes else {
            state = .failed; throw WireError.invalidSequence
        }
        state = .completed
        return TransferCompletion(transferID: manifest.transferID, projectID: projectID, manifestDigest: try manifest.digest())
    }
    public mutating func cancel() { active = nil; state = .cancelled }
    public mutating func interrupt() { active = nil; state = .interrupted }
}

/// Journal identity helper only. Disk persistence and mandatory rehashing belong to the future staging service.
public struct ResumeDescriptor: Codable, Equatable, Sendable {
    public let transferID: UUID
    public let captureID: UUID
    public let manifestDigest: String
    public let verifiedIndices: Set<Int>
    public init(manifest: TransferManifest, verifiedIndices: Set<Int>) throws {
        guard verifiedIndices.allSatisfy(manifest.files.indices.contains) else { throw WireError.invalidManifest }
        transferID = manifest.transferID; captureID = manifest.captureID
        manifestDigest = try manifest.digest(); self.verifiedIndices = verifiedIndices
    }
    public func candidates(for manifest: TransferManifest) throws -> Set<Int> {
        guard transferID == manifest.transferID, captureID == manifest.captureID,
              manifestDigest == (try manifest.digest()), verifiedIndices.allSatisfy(manifest.files.indices.contains) else { return [] }
        return verifiedIndices
    }
}
