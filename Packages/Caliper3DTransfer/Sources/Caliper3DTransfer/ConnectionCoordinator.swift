import Foundation
import Observation
import Network
import Security
import Caliper3DCore

public struct AvailableMac: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
}
public struct ConnectedPeer: Equatable, Sendable {
    public let fingerprint: String
    public let name: String
    public let operatingSystem: String
    public let objectCaptureSupported: Bool?
}
public enum DiscoveryStatus: Equatable, Sendable { case stopped, preparing, ready, failed(String) }
public enum ConnectionStatus: Equatable, Sendable {
    case offline, connecting, exchangingIdentity, awaitingCode, savingTrust, verification(String), waitingForConfirmation(String)
    case connected(ConnectedPeer), failed(String)
    public var message: String {
        switch self {
        case .offline: "Not connected"
        case .connecting: "Connecting…"
        case .exchangingIdentity: "Checking device identity…"
        case .awaitingCode: "Preparing verification code…"
        case .savingTrust: "Saving trusted device…"
        case .verification: "Compare the code on both devices"
        case .waitingForConfirmation: "Waiting for the other device to confirm"
        case .connected(let peer): "Connected to \(peer.name)"
        case .failed(let message): message
        }
    }
}
public struct PairingAttemptGate: Sendable {
    private var attempts: [Date] = []
    public init() {}
    public mutating func admit(now: Date = Date()) -> Bool {
        attempts.removeAll { now.timeIntervalSince($0) >= 60 }
        guard attempts.count < 3, attempts.last.map({ now.timeIntervalSince($0) >= 3 }) ?? true else { return false }
        attempts.append(now); return true
    }
}

/// App-lifetime UI-facing coordinator. TLSChannel owns byte I/O; protocol/security models own
/// validation. All transfer frames remain rejected until a transfer engine is installed.
@MainActor @Observable
public final class ConnectionCoordinator {
    public let role: PairingSession.Role
    public private(set) var discovery: DiscoveryStatus = .stopped
    public private(set) var state: ConnectionStatus = .offline
    public private(set) var macs: [AvailableMac] = []
    public private(set) var trustedPeers: [TrustedPeer] = []
    public private(set) var pairingWindowOpen = false
    public private(set) var peerName: String?
    private let name: String
    private let operatingSystem: String
    private let captureSupported: Bool?
    private let trustStore: any PeerTrustStore
    private let identityLoader: @MainActor () async throws -> LocalTLSIdentity
    private var identity: LocalTLSIdentity?
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var endpoints: [String: NWEndpoint] = [:]
    private var channel: TLSChannel?
    private var binding: TLSBinding?
    private var hello: PeerHello?
    private var pairing: PairingSession?
    private var requestedPairing = false
    private var readTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var windowTask: Task<Void, Never>?
    private var generation = UUID()
    private var gate = PairingAttemptGate()
    private var started = false
    private let loopbackOnly: Bool
    var listeningPort: NWEndpoint.Port? { listener?.port }

    public init(role: PairingSession.Role, name: String, operatingSystem: String, captureSupported: Bool?,
                trustStore: any PeerTrustStore = KeychainTrustRepository(),
                identityLoader: @escaping @MainActor () async throws -> LocalTLSIdentity = {
                    try await KeychainIdentityRepository.load(from: KeychainIdentityRepository())
                }) {
        self.role = role; self.name = name; self.operatingSystem = operatingSystem; self.captureSupported = captureSupported
        self.trustStore = trustStore; self.identityLoader = identityLoader; loopbackOnly = false
    }
    // No Bonjour/Keychain access in coordinator integration tests.
    init(role: PairingSession.Role, name: String, trustStore: any PeerTrustStore, identity: LocalTLSIdentity) {
        self.role = role; self.name = name; operatingSystem = "Test"; captureSupported = nil
        self.trustStore = trustStore; identityLoader = { identity }; loopbackOnly = true
    }
    public func start() async {
        guard !started else { return }; started = true; discovery = .preparing
        let token = UUID(); generation = token
        do {
            let loadedIdentity = try await identityLoader()
            guard started, generation == token else { return }
            identity = loadedIdentity; try await reloadTrust()
            guard started, generation == token else { return }
            if role == .mac { try listen() } else if !loopbackOnly { browse() }
        } catch { if generation == token { started = false; discovery = .failed(Self.message(error)); state = .failed(Self.message(error)) } }
    }
    public func stop() async {
        started = false; windowTask?.cancel(); pairingWindowOpen = false
        listener?.cancel(); listener = nil; browser?.cancel(); browser = nil; endpoints = [:]; macs = []
        await disconnect(); discovery = .stopped
    }
    public func disconnect() async {
        generation = UUID(); readTask?.cancel(); timeoutTask?.cancel(); pairing?.reject()
        let previous = channel; channel = nil; binding = nil; hello = nil; pairing = nil; peerName = nil
        state = .offline; await previous?.close()
    }
    public func background() async {
        await stop(); state = .failed("Reopen Caliper3D Capture to continue. Saved captures are unchanged.")
    }
    public func allowPairing() async {
        guard role == .mac, channel == nil else { return }
        if !started { await start() }
        guard started, identity != nil else { return }
        pairingWindowOpen = true
        do { try listen() } catch { state = .failed(Self.message(error)); pairingWindowOpen = false }
        windowTask?.cancel()
        windowTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(120)) } catch { return }
            guard let self else { return }
            self.pairingWindowOpen = false
            try? self.listen()
        }
    }
    public func closePairingWindow() async {
        windowTask?.cancel(); pairingWindowOpen = false
        if pairing != nil { await disconnect() }
        do { try listen() } catch { state = .failed(Self.message(error)) }
    }
    public func connect(macID: String, expectedFingerprint: String? = nil) async {
        guard let endpoint = endpoints[macID] else { state = .failed("This Mac is no longer available. Keep both apps open on the same network."); return }
        await connect(endpoint: endpoint, expectedFingerprint: expectedFingerprint)
    }
    func connect(endpoint: NWEndpoint, expectedFingerprint: String?) async {
        guard role == .phone, started, channel == nil, let identity else { return }
        let token = generation
        do {
            if let expectedFingerprint {
                let records = try await trustStore.records()
                try records.requirePinned(expected: expectedFingerprint, presented: expectedFingerprint)
            } else if !gate.admit() { throw PairingError.rejected }
            guard started, generation == token else { return }
            requestedPairing = expectedFingerprint == nil
            let parameters = try LocalTLSParameters.make(identity: identity, policy: expectedFingerprint.map(TLSPeerPolicy.pinned) ?? .firstPair)
            launch(NWConnection(to: endpoint, using: parameters), pairingAllowed: requestedPairing)
        } catch { state = .failed(Self.message(error)) }
    }
    public func confirm() async {
        guard case .verification(let code) = state, var session = pairing else { return }
        let token = generation
        do {
            let digest = try session.confirmLocally(); pairing = session
            state = .waitingForConfirmation(code)
            try await send(.init(type: .pairingConfirmation, payload: .confirmation(.init(transcriptDigest: digest))))
            guard token == generation else { return }
            try await approveIfReady()
        } catch { await fail(error, token: token) }
    }
    public func reject() async { await disconnect(); state = .failed("Pairing declined. No new trust was granted.") }
    public func forget(_ fingerprint: String) async {
        do {
            if binding?.peerFingerprint == fingerprint { await disconnect() }
            try await trustStore.forget(fingerprint); try await reloadTrust()
            if role == .mac { try listen() }
        } catch { state = .failed(Self.message(error)) }
    }
    private func reloadTrust() async throws { trustedPeers = try await trustStore.records().peers }
    private func listen() throws {
        guard role == .mac, let identity else { return }
        listener?.cancel(); listener = nil
        let policy: TLSPeerPolicy = pairingWindowOpen ? .firstPair : .trusted(Set(trustedPeers.map(\.fingerprint)))
        let parameters = try LocalTLSParameters.make(identity: identity, policy: policy)
        if loopbackOnly { parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any) }
        let current = try NWListener(using: parameters)
        current.newConnectionLimit = 4
        if !loopbackOnly { current.service = NWListener.Service(name: name, type: TransferPolicy.bonjourType) }
        let acceptsPairing = pairingWindowOpen
        current.newConnectionHandler = { [weak self, weak current] connection in
            Task { @MainActor in
                guard let self, self.listener === current, self.channel == nil,
                      !acceptsPairing || (self.pairingWindowOpen && self.gate.admit()) else { connection.cancel(); return }
                self.launch(connection, pairingAllowed: acceptsPairing)
            }
        }
        current.stateUpdateHandler = { [weak self, weak current] status in
            Task { @MainActor in
                guard let self, self.listener === current else { return }
                switch status {
                case .ready: self.discovery = .ready
                case .failed: self.discovery = .failed("Local network access failed. Check Caliper3D in System Settings → Privacy & Security → Local Network.")
                case .cancelled: self.discovery = .stopped
                default: self.discovery = .preparing
                }
            }
        }
        listener = current; discovery = .preparing; current.start(queue: DispatchQueue(label: "org.caliper3d.listener"))
    }
    private func browse() {
        browser?.cancel()
        let parameters = NWParameters.tcp; parameters.includePeerToPeer = false
        let current = NWBrowser(for: .bonjour(type: TransferPolicy.bonjourType, domain: nil), using: parameters)
        current.stateUpdateHandler = { [weak self, weak current] status in
            Task { @MainActor in
                guard let self, self.browser === current else { return }
                switch status {
                case .ready: self.discovery = .ready
                case .failed, .waiting:
                    self.discovery = .failed("Cannot search the local network. Allow Caliper3D Capture in Settings → Privacy & Security → Local Network, then retry.")
                    current?.cancel(); self.browser = nil; self.endpoints = [:]; self.macs = []; self.started = false
                case .cancelled: self.discovery = .stopped
                default: self.discovery = .preparing
                }
            }
        }
        current.browseResultsChangedHandler = { [weak self, weak current] results, _ in
            Task { @MainActor in
                guard let self, self.browser === current else { return }
                var endpoints: [String: NWEndpoint] = [:]; var peers: [String: AvailableMac] = [:]
                for result in results {
                    if case .service(let name, let type, let domain, _) = result.endpoint {
                        let key = name + "\n" + type + "\n" + domain
                        endpoints[key] = result.endpoint; peers[key] = AvailableMac(id: key, name: name)
                    }
                }
                self.endpoints = endpoints; self.macs = peers.values.sorted { $0.name < $1.name }
            }
        }
        browser = current; current.start(queue: DispatchQueue(label: "org.caliper3d.browser"))
    }
    private func launch(_ connection: NWConnection, pairingAllowed: Bool) {
        let token = UUID(); generation = token; requestedPairing = pairingAllowed
        let transport = TLSChannel(connection: connection); channel = transport; state = .connecting
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(120)) } catch { return }
            guard let self, self.generation == token else { return }
            if case .connected = self.state { return }
            await self.fail(PairingError.expired, token: token)
        }
        readTask = Task { [weak self] in
            do {
                let binding = try await transport.start()
                guard let self, self.generation == token else { await transport.close(); return }
                self.binding = binding; self.state = .exchangingIdentity
                if self.role == .phone { try await self.sendHello(type: .hello, requiresPairing: pairingAllowed) }
                var decoder = FrameDecoder()
                while let bytes = try await transport.receive() {
                    guard self.generation == token else { return }
                    for frame in try decoder.append(bytes) {
                        try await self.process(frame)
                        guard self.generation == token else { return }
                    }
                }
                try decoder.finish(); throw WireError.truncatedFrame
            } catch { await self?.fail(error, token: token) }
        }
    }
    private func sendHello(type: ControlMessage.Kind, requiresPairing: Bool) async throws {
        guard let identity else { throw PairingError.invalidIdentity }
        var nonce = Data(count: 32)
        let status = nonce.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard status == errSecSuccess else { throw PairingError.keychain(status) }
        try await send(.init(type: type, payload: .hello(.init(name: name, operatingSystem: operatingSystem,
            objectCaptureSupported: captureSupported, identityFingerprint: identity.fingerprint,
            nonce: TransferPolicy.hex(nonce), requiresPairing: requiresPairing))))
    }
    private func process(_ frame: WireFrame) async throws {
        let token = generation
        guard case .control(let message) = frame, let binding else { throw WireError.invalidSequence }
        switch (message.type, message.payload) {
        case (.hello, .hello(let value)), (.helloResponse, .hello(let value)):
            guard state == .exchangingIdentity, hello == nil,
                  message.type == (role == .mac ? .hello : .helloResponse),
                  value.identityFingerprint == binding.peerFingerprint else { throw PairingError.mismatch }
            hello = value; peerName = value.name
            let needsPairing = value.requiresPairing == true
            if role == .phone {
                guard needsPairing == requestedPairing else { throw PairingError.mismatch }
            } else if needsPairing && !requestedPairing { throw PairingError.mismatch }
            if role == .mac { try await sendHello(type: .helloResponse, requiresPairing: needsPairing) }
            if needsPairing {
                guard let identity else { throw PairingError.invalidIdentity }
                let session = try binding.pairing(role: role, localFingerprint: identity.fingerprint)
                pairing = session; state = .awaitingCode
                try await send(.init(type: .pairingCommitment, payload: .commitment(.init(sha256: session.commitment))))
            } else {
                let trust = try await trustStore.records()
                try trust.requirePinned(expected: binding.peerFingerprint, presented: value.identityFingerprint)
                guard token == generation else { throw WireError.cancelled }
                connected()
            }
        case (.pairingCommitment, .commitment(let value)):
            guard var session = pairing, state == .awaitingCode else { throw WireError.invalidSequence }
            try session.receiveCommitment(value.sha256); let nonce = try session.reveal(); pairing = session
            try await send(.init(type: .pairingReveal, payload: .reveal(.init(nonce: nonce))))
        case (.pairingReveal, .reveal(let value)):
            guard var session = pairing, state == .awaitingCode else { throw WireError.invalidSequence }
            try session.receiveReveal(value.nonce); pairing = session
            guard let code = session.verificationCode else { throw PairingError.invalidMessage }; state = .verification(code)
        case (.pairingConfirmation, .confirmation(let value)):
            guard var session = pairing else { throw WireError.invalidSequence }
            try session.receiveConfirmation(value.transcriptDigest); pairing = session; try await approveIfReady()
        default: throw WireError.invalidSequence // no transfer allowed through an unimplemented path
        }
    }
    private func approveIfReady() async throws {
        guard let pairing, pairing.state == .approved, let hello, state != .savingTrust else { return }
        state = .savingTrust
        let token = generation
        try await trustStore.approve(pairing, name: hello.name)
        guard token == generation else { return }
        try await reloadTrust()
        guard token == generation else { return }
        connected()
        if role == .mac { pairingWindowOpen = false; windowTask?.cancel(); try listen() }
    }
    private func connected() {
        guard let hello, let binding else { return }
        timeoutTask?.cancel(); pairing = nil
        state = .connected(ConnectedPeer(fingerprint: binding.peerFingerprint, name: hello.name,
            operatingSystem: hello.operatingSystem, objectCaptureSupported: hello.objectCaptureSupported))
        AppLog.network.info("Peer authenticated")
    }
    private func send(_ message: ControlMessage) async throws {
        guard let channel else { throw WireError.cancelled }
        let token = generation
        try await channel.send(WireFrame.control(message).encoded())
        guard token == generation else { throw WireError.cancelled }
    }
    private func fail(_ error: Error, token: UUID) async {
        guard generation == token else { return }
        await disconnect(); state = .failed(Self.message(error))
    }
    private static func message(_ error: Error) -> String {
        if let pairing = error as? PairingError { return pairing.localizedDescription }
        if let wire = error as? WireError { return wire.localizedDescription }
        return "Connection interrupted or device identity could not be verified. Keep both apps on the same local network. If the device identity changed, forget it and explicitly pair again."
    }
}
