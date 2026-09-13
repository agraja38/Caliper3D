import XCTest
import Network
import Caliper3DCore
@testable import Caliper3DTransfer

private actor MemoryTrust: PeerTrustStore {
    var value = TrustRecords()
    var approvals = 0
    func records() -> TrustRecords { value }
    func approve(_ session: PairingSession, name: String) throws { try value.approve(session, name: name); approvals += 1 }
    func forget(_ fingerprint: String) { value.forget(fingerprint) }
}
@MainActor
final class CoordinatorTests: XCTestCase {
    func wait(_ condition: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<1000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw WireError.timedOut
    }
    func testPairBothConfirmThenPinnedReconnectAndForget() async throws {
        let phoneIdentity = try LocalTLSIdentity(material: IdentityCertificate.createMaterial())
        let macIdentity = try LocalTLSIdentity(material: IdentityCertificate.createMaterial())
        let phoneTrust = MemoryTrust(), macTrust = MemoryTrust()
        let phone = ConnectionCoordinator(role: .phone, name: "Test Phone", trustStore: phoneTrust, identity: phoneIdentity)
        let mac = ConnectionCoordinator(role: .mac, name: "Test Mac", trustStore: macTrust, identity: macIdentity)
        await mac.start(); await phone.start(); await mac.allowPairing()
        try await wait { mac.discovery == .ready && mac.listeningPort != nil }
        await phone.connect(endpoint: .hostPort(host: "127.0.0.1", port: try XCTUnwrap(mac.listeningPort)), expectedFingerprint: nil)
        try await wait { if case .verification = phone.state, case .verification = mac.state { return true }; return false }
        guard case .verification(let pc) = phone.state, case .verification(let mc) = mac.state else { return XCTFail() }
        XCTAssertEqual(pc, mc)
        var savedPhone = await phoneTrust.approvals, savedMac = await macTrust.approvals
        XCTAssertEqual(savedPhone, 0); XCTAssertEqual(savedMac, 0)
        await phone.confirm()
        try await Task.sleep(for: .milliseconds(50))
        savedPhone = await phoneTrust.approvals; savedMac = await macTrust.approvals
        XCTAssertEqual(savedPhone, 0); XCTAssertEqual(savedMac, 0)
        await mac.confirm()
        try await wait { if case .connected = phone.state, case .connected = mac.state { return true }; return false }
        XCTAssertEqual(phone.trustedPeers.first?.fingerprint, macIdentity.fingerprint)
        XCTAssertEqual(mac.trustedPeers.first?.fingerprint, phoneIdentity.fingerprint)
        XCTAssertFalse(mac.pairingWindowOpen)
        await phone.stop(); await mac.stop(); await phone.start(); await mac.start()
        try await wait { mac.discovery == .ready && mac.listeningPort != nil }
        await phone.connect(endpoint: .hostPort(host: "127.0.0.1", port: try XCTUnwrap(mac.listeningPort)), expectedFingerprint: macIdentity.fingerprint)
        try await wait { if case .connected = phone.state, case .connected = mac.state { return true }; return false }
        await phone.forget(macIdentity.fingerprint)
        XCTAssertTrue(phone.trustedPeers.isEmpty)
        await phone.connect(endpoint: .hostPort(host: "127.0.0.1", port: try XCTUnwrap(mac.listeningPort)), expectedFingerprint: macIdentity.fingerprint)
        guard case .failed = phone.state else { return XCTFail("Forgotten pin must fail before reconnect") }
        await phone.stop(); await mac.stop()
    }
    func testHelloFingerprintMismatchCannotPair() async throws {
        let macIdentity = try LocalTLSIdentity(material: IdentityCertificate.createMaterial())
        let phoneIdentity = try LocalTLSIdentity(material: IdentityCertificate.createMaterial())
        let trust = MemoryTrust()
        let mac = ConnectionCoordinator(role: .mac, name: "Test Mac", trustStore: trust, identity: macIdentity)
        await mac.start(); await mac.allowPairing()
        try await wait { mac.discovery == .ready && mac.listeningPort != nil }
        let channel = TLSChannel(connection: NWConnection(host: "127.0.0.1", port: try XCTUnwrap(mac.listeningPort),
            using: try LocalTLSParameters.make(identity: phoneIdentity, policy: .firstPair)))
        _ = try await channel.start()
        let forged = PeerHello(name: "Forged", operatingSystem: "Test", objectCaptureSupported: nil,
            identityFingerprint: macIdentity.fingerprint, nonce: String(repeating: "0", count: 64), requiresPairing: true)
        try await channel.send(WireFrame.control(.init(type: .hello, payload: .hello(forged))).encoded())
        try await wait { if case .failed = mac.state { return true }; return false }
        let records = await trust.records(); XCTAssertTrue(records.peers.isEmpty)
        await channel.close(); await mac.stop()
    }
    func testRateLimitExpiresAndHasCooldown() {
        var gate = PairingAttemptGate(); let now = Date()
        XCTAssertTrue(gate.admit(now: now)); XCTAssertFalse(gate.admit(now: now.addingTimeInterval(1)))
        XCTAssertTrue(gate.admit(now: now.addingTimeInterval(3)))
        XCTAssertTrue(gate.admit(now: now.addingTimeInterval(6)))
        XCTAssertFalse(gate.admit(now: now.addingTimeInterval(9)))
        XCTAssertTrue(gate.admit(now: now.addingTimeInterval(61)))
    }
}


extension CoordinatorTests {
    func paired(incoming: IncomingCaptureStore) async throws -> (ConnectionCoordinator, ConnectionCoordinator) {
        let phone = ConnectionCoordinator(role: .phone, name: "Synthetic Phone", trustStore: MemoryTrust(), identity: try LocalTLSIdentity(material: IdentityCertificate.createMaterial()))
        let mac = ConnectionCoordinator(role: .mac, name: "Synthetic Mac", trustStore: MemoryTrust(), identity: try LocalTLSIdentity(material: IdentityCertificate.createMaterial()), incomingStore: incoming)
        await mac.start(); await phone.start(); await mac.allowPairing()
        try await wait { mac.discovery == .ready && mac.listeningPort != nil }
        await phone.connect(endpoint: .hostPort(host: "127.0.0.1", port: try XCTUnwrap(mac.listeningPort)), expectedFingerprint: nil)
        try await wait { if case .verification = phone.state, case .verification = mac.state { return true }; return false }
        await phone.confirm(); await mac.confirm()
        try await wait { if case .connected = phone.state, case .connected = mac.state { return true }; return false }
        return (phone, mac)
    }
    func dataset(_ root: URL, chunks: Int = 4) async throws -> (LocalCaptureRepository, UUID) {
        let repository = LocalCaptureRepository(root: root.appendingPathComponent("Phone"), sourceDevice: .init(name: "Synthetic Phone", operatingSystem: "Test", objectCaptureSupported: true))
        let allocation = try await repository.allocate(name: "Synthetic Mouse")
        try Data([1,2,3]).write(to: allocation.checkpoints.appendingPathComponent("points"))
        let url = allocation.images.appendingPathComponent("image.heic")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        for _ in 0..<chunks { try handle.write(contentsOf: Data(repeating: 42, count: TransferPolicy.chunkBytes)) }
        try handle.close(); _ = try await repository.complete(allocation.id)
        return (repository, allocation.id)
    }
    func testLiveTransferRequiresAcceptanceThenCommitsAndAcknowledges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let projects = LocalProjectStore(root: root.appendingPathComponent("Projects"))
        let incoming = IncomingCaptureStore(root: root.appendingPathComponent("Incoming"), projects: projects)
        let (phone, mac) = try await paired(incoming: incoming)
        let (repository, id) = try await dataset(root)
        await phone.sendCapture(id, repository: repository)
        try await wait { mac.transfer == .offered }
        var library = try await projects.list(); XCTAssertTrue(library.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Incoming").path))
        await mac.declineCapture()
        try await wait { phone.transfer == .declined }
        await phone.sendCapture(id, repository: repository)
        try await wait { mac.transfer == .offered }
        await mac.acceptCapture()
        try await wait { phone.transfer == .completed && mac.transfer == .completed }
        library = try await projects.list(); XCTAssertEqual(library.map(\.id), [id])
        XCTAssertEqual(library.first?.manifest.reconstructionState, .notStarted)
        let source = try await repository.prepareSource(id); _ = try await source.describe()
        // A second offer on the same trusted connection returns an existing exact dataset safely.
        await phone.sendCapture(id, repository: repository)
        try await wait { mac.transfer == .offered }; await mac.acceptCapture()
        try await wait { phone.transfer == .completed && mac.transfer == .completed }
        library = try await projects.list(); XCTAssertEqual(library.count, 1)
        await phone.stop(); await mac.stop()
    }
    func testLiveAllVerifiedResumeFinalizesWithoutFileFrames() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let projects = LocalProjectStore(root: root.appendingPathComponent("Projects"))
        let incomingURL = root.appendingPathComponent("Incoming")
        let oldStore = IncomingCaptureStore(root: incomingURL, projects: projects)
        let (repository, id) = try await dataset(root)
        let prepared = try await PreparedCaptureTransfer.prepare(captureID: id, repository: repository)
        _ = try await oldStore.prepare(prepared.manifest)
        for index in prepared.manifest.files.indices { try await IncomingStoreTests().send(prepared, index: index, store: oldStore) }
        try await oldStore.cancel()
        let (phone, mac) = try await paired(incoming: IncomingCaptureStore(root: incomingURL, projects: projects))
        await phone.sendCapture(id, repository: repository)
        try await wait { mac.transfer == .offered }; await mac.acceptCapture()
        try await wait { phone.transfer == .completed && mac.transfer == .completed }
        XCTAssertEqual(phone.resumedFileCount, prepared.manifest.files.count)
        await phone.stop(); await mac.stop()
    }
    func testLiveCancelMidFileThenPinnedReconnectResumesVerifiedFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let projects = LocalProjectStore(root: root.appendingPathComponent("Projects"))
        let incoming = IncomingCaptureStore(root: root.appendingPathComponent("Incoming"), projects: projects)
        let (phone, mac) = try await paired(incoming: incoming)
        let pin = try XCTUnwrap(phone.trustedPeers.first?.fingerprint)
        let (repository, id) = try await dataset(root, chunks: 256)
        await phone.sendCapture(id, repository: repository)
        try await wait { mac.transfer == .offered }; await mac.acceptCapture()
        try await wait { if case .transferring(let bytes, let total, _) = mac.transfer { return bytes > 1_000_000 && bytes < total }; return false }
        await phone.cancelTransfer()
        try await wait { if case .failed = mac.state { return true }; return false }
        var library = try await projects.list(); XCTAssertTrue(library.isEmpty)
        await phone.connect(endpoint: .hostPort(host: "127.0.0.1", port: try XCTUnwrap(mac.listeningPort)), expectedFingerprint: pin)
        try await wait { if case .connected = phone.state, case .connected = mac.state { return true }; return false }
        await phone.sendCapture(id, repository: repository)
        try await wait { mac.transfer == .offered }; await mac.acceptCapture()
        try await wait { phone.transfer == .completed && mac.transfer == .completed }
        XCTAssertGreaterThan(phone.resumedFileCount, 0)
        library = try await projects.list(); XCTAssertEqual(library.count, 1)
        _ = try await repository.prepareSource(id)
        await phone.stop(); await mac.stop()
    }
}
