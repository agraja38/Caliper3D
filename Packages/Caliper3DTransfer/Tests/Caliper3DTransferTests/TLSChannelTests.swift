import XCTest
import Network
@testable import Caliper3DTransfer

final class TLSChannelTests: XCTestCase {
    func listenerParameters(_ identity: LocalTLSIdentity) throws -> NWParameters {
        let parameters = try LocalTLSParameters.make(identity: identity, policy: .firstPair)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        return parameters
    }
    func incoming(_ stream: AsyncStream<NWConnection>) async throws -> NWConnection {
        try await withThrowingTaskGroup(of: NWConnection.self) { group in
            group.addTask { for await connection in stream { return connection }; throw WireError.cancelled }
            group.addTask { try await Task.sleep(for: .seconds(10)); throw WireError.timedOut }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
    func testRealLoopbackTLSExporterMatchesAndCarriesBoundedBytes() async throws {
        let serverIdentity = try LocalTLSIdentity(material: IdentityCertificate.createMaterial())
        let clientIdentity = try LocalTLSIdentity(material: IdentityCertificate.createMaterial())
        let listener = try NWListener(using: listenerParameters(serverIdentity), on: .any)
        let arrivals = AsyncStream<NWConnection>.makeStream(bufferingPolicy: .bufferingNewest(1))
        listener.newConnectionHandler = { arrivals.continuation.yield($0) }
        let listening = expectation(description: "listener ready")
        listener.stateUpdateHandler = { if case .ready = $0 { listening.fulfill() } }
        listener.start(queue: DispatchQueue(label: "caliper.test.listener"))
        defer { listener.cancel(); arrivals.continuation.finish() }
        await fulfillment(of: [listening], timeout: 5)
        let port = try XCTUnwrap(listener.port)
        let client = TLSChannel(connection: NWConnection(host: "127.0.0.1", port: port,
            using: try LocalTLSParameters.make(identity: clientIdentity, policy: .pinned(serverIdentity.fingerprint))))
        async let clientResult = client.start()
        let server = TLSChannel(connection: try await incoming(arrivals.stream))
        let serverResult = try await server.start()
        let clientBinding = try await clientResult
        XCTAssertEqual(clientBinding.peerFingerprint, serverIdentity.fingerprint)
        XCTAssertEqual(serverResult.peerFingerprint, clientIdentity.fingerprint)
        XCTAssertEqual(clientBinding.exporter, serverResult.exporter)
        var phonePairing = try clientBinding.pairing(role: .phone, localFingerprint: clientIdentity.fingerprint)
        var macPairing = try serverResult.pairing(role: .mac, localFingerprint: serverIdentity.fingerprint)
        let pc = phonePairing.commitment, mc = macPairing.commitment
        try phonePairing.receiveCommitment(mc); try macPairing.receiveCommitment(pc)
        let pr = try phonePairing.reveal(), mr = try macPairing.reveal()
        try phonePairing.receiveReveal(mr); try macPairing.receiveReveal(pr)
        XCTAssertEqual(phonePairing.verificationCode, macPairing.verificationCode)
        let bytes = try WireFrame.binary(Data(repeating: 42, count: TransferPolicy.chunkBytes)).encoded()
        async let sending: Void = client.send(bytes)
        var received = Data()
        while received.count < bytes.count {
            guard let chunk = try await server.receive() else { throw WireError.truncatedFrame }
            XCTAssertLessThanOrEqual(chunk.count, TransferPolicy.receiveBytes); received.append(chunk)
        }
        try await sending
        XCTAssertEqual(received, bytes)
        await client.close(); await server.close()
    }
    func testPinnedMismatchFailsRealTLSHandshake() async throws {
        let serverIdentity = try LocalTLSIdentity(material: IdentityCertificate.createMaterial())
        let clientIdentity = try LocalTLSIdentity(material: IdentityCertificate.createMaterial())
        let listener = try NWListener(using: listenerParameters(serverIdentity), on: .any)
        let arrivals = AsyncStream<NWConnection>.makeStream(bufferingPolicy: .bufferingNewest(1))
        listener.newConnectionHandler = { arrivals.continuation.yield($0) }
        let listening = expectation(description: "listener ready")
        listener.stateUpdateHandler = { if case .ready = $0 { listening.fulfill() } }
        listener.start(queue: DispatchQueue(label: "caliper.test.pin"))
        defer { listener.cancel(); arrivals.continuation.finish() }
        await fulfillment(of: [listening], timeout: 5)
        let client = TLSChannel(connection: NWConnection(host: "127.0.0.1", port: try XCTUnwrap(listener.port),
            using: try LocalTLSParameters.make(identity: clientIdentity, policy: .pinned(String(repeating: "0", count: 64)))))
        let clientTask = Task { try await client.start() }
        let server = TLSChannel(connection: try await incoming(arrivals.stream))
        let serverTask = Task { try await server.start() }
        do { _ = try await clientTask.value; XCTFail("A mismatched pin must never connect") } catch { }
        await client.close(); await server.close()
        _ = try? await serverTask.value
    }
}
