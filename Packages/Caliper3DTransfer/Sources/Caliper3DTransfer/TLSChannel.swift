import Foundation
import Network
import Security
import Caliper3DCore

public enum TLSPeerPolicy: Sendable {
    /// Only for an explicit Pair action. Grants an encrypted channel, never transfer authorization.
    case firstPair
    /// The expected fingerprint must come from Keychain trust, never Bonjour/hello metadata.
    case pinned(String)
}
public enum LocalTLSParameters {
    public static func make(identity: LocalTLSIdentity, policy: TLSPeerPolicy) throws -> NWParameters {
        guard let securityIdentity = sec_identity_create(identity.identity) else { throw PairingError.invalidIdentity }
        if case .pinned(let fingerprint) = policy, !TransferPolicy.isSHA256(fingerprint) { throw PairingError.invalidIdentity }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, securityIdentity)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
        sec_protocol_options_set_peer_authentication_required(tls.securityProtocolOptions, true)
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
            let trustRef = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let chain = SecTrustCopyCertificateChain(trustRef) as? [SecCertificate], chain.count == 1,
                  let leaf = chain.first else { complete(false); return }
            let bytes = SecCertificateCopyData(leaf) as Data
            guard bytes.count <= 16_384 else { complete(false); return }
            let fingerprint = TransferPolicy.digest(bytes)
            if case .pinned(let expected) = policy, expected != fingerprint { complete(false); return }
            // App identities are self-issued. Validate their structure/validity using this exact
            // certificate as the sole anchor. First-pair user verification is still mandatory.
            guard SecTrustSetPolicies(trustRef, SecPolicyCreateBasicX509()) == errSecSuccess,
                  SecTrustSetAnchorCertificates(trustRef, [leaf] as CFArray) == errSecSuccess,
                  SecTrustSetAnchorCertificatesOnly(trustRef, true) == errSecSuccess,
                  SecTrustSetNetworkFetchAllowed(trustRef, false) == errSecSuccess else { complete(false); return }
            complete(SecTrustEvaluateWithError(trustRef, nil))
        }, DispatchQueue(label: "org.caliper3d.tls.verify"))
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.includePeerToPeer = false
        return parameters
    }
}
public struct TLSBinding: Sendable {
    public let peerFingerprint: String
    /// Live TLS channel secret. Never serialize or log it.
    let exporter: Data
    public func pairing(role: PairingSession.Role, localFingerprint: String) throws -> PairingSession {
        try PairingSession(role: role, phoneFingerprint: role == .phone ? localFingerprint : peerFingerprint,
            macFingerprint: role == .mac ? localFingerprint : peerFingerprint,
            tlsPeerFingerprint: peerFingerprint, tlsExporter: exporter)
    }
}

/// Bounded byte transport. Provides encryption/channel binding only; callers still must gate
/// every file operation on pairing and an explicit Receive decision. One reader and writer.
public actor TLSChannel {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "org.caliper3d.tls.connection")
    private var started = false
    private var closed = false
    private var isReady = false
    private var reading = false
    private var writing = false
    private var ready: CheckedContinuation<TLSBinding, Error>?
    public init(connection: NWConnection) { self.connection = connection }
    deinit { connection.cancel() }
    public func start() async throws -> TLSBinding {
        guard !started, !closed else { throw WireError.invalidSequence }
        started = true
        AppLog.network.info("Starting local TLS connection")
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                ready = continuation
                connection.stateUpdateHandler = { [weak self] state in Task { await self?.transition(state) } }
                connection.start(queue: queue)
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(15))
                    await self?.handshakeTimeout()
                }
            }
        } onCancel: { Task { await self.close() } }
    }
    public func send(_ data: Data) async throws {
        guard !closed, isReady, !writing, data.count <= TransferPolicy.maximumControlBytes + 5 else { throw WireError.invalidSequence }
        writing = true
        let timeout = operationTimeout()
        defer { writing = false; timeout.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                })
            }
        } onCancel: { Task { await self.close() } }
    }
    public func receive() async throws -> Data? {
        guard !closed, isReady, !reading else { throw WireError.invalidSequence }
        reading = true
        let timeout = operationTimeout()
        defer { reading = false; timeout.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: TransferPolicy.receiveBytes) { data, _, complete, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let data, !data.isEmpty { continuation.resume(returning: data) }
                    else if complete { continuation.resume(returning: nil) }
                    else { continuation.resume(throwing: WireError.truncatedFrame) }
                }
            }
        } onCancel: { Task { await self.close() } }
    }
    public func close() {
        guard !closed else { return }
        AppLog.network.info("Closing local TLS connection")
        closed = true; isReady = false; connection.cancel()
        ready?.resume(throwing: WireError.cancelled); ready = nil
    }
    private func operationTimeout() -> Task<Void, Never> {
        Task { [weak self] in
            do { try await Task.sleep(for: .seconds(180)); await self?.close() } catch { }
        }
    }
    private func handshakeTimeout() {
        if ready != nil { ready?.resume(throwing: WireError.timedOut); ready = nil; close() }
    }
    private func transition(_ state: NWConnection.State) {
        switch state {
        case .ready:
            guard let continuation = ready else { return }
            ready = nil
            do { let result = try binding(); isReady = true; AppLog.network.info("Local TLS channel ready"); continuation.resume(returning: result) }
            catch { continuation.resume(throwing: error); close() }
        case .failed(let error): ready?.resume(throwing: error); ready = nil; close()
        case .cancelled: ready?.resume(throwing: WireError.cancelled); ready = nil; closed = true
        default: break
        }
    }
    private func binding() throws -> TLSBinding {
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else { throw PairingError.invalidIdentity }
        var certificates: [Data] = []
        let accessible = sec_protocol_metadata_access_peer_certificate_chain(metadata.securityProtocolMetadata) { certificate in
            certificates.append(SecCertificateCopyData(sec_certificate_copy_ref(certificate).takeRetainedValue()) as Data)
        }
        guard accessible, certificates.count == 1, let certificate = certificates.first else { throw PairingError.invalidIdentity }
        let label = "EXPORTER-Caliper3D-pairing-v1"
        let exported = label.withCString { sec_protocol_metadata_create_secret(metadata.securityProtocolMetadata, label.utf8.count, $0, 32) }
        guard let exported else { throw PairingError.invalidIdentity }
        return TLSBinding(peerFingerprint: TransferPolicy.digest(certificate), exporter: Data(exported as DispatchData))
    }
}
