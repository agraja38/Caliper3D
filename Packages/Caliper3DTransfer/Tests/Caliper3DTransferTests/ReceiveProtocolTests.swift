import XCTest
@testable import Caliper3DTransfer

final class ReceiveProtocolTests: XCTestCase {
    let fingerprint = String(repeating: "a", count: 64)
    func hello() -> WireFrame {
        .control(.init(type: .hello, payload: .hello(.init(name: "Test", operatingSystem: "iOS", objectCaptureSupported: true,
            identityFingerprint: fingerprint, nonce: String(repeating: "b", count: 64)))))
    }
    func offered(_ manifest: TransferManifest) throws -> ReceiveProtocol {
        var receiver = ReceiveProtocol(); try receiver.receive(hello())
        try receiver.authorizePeer(tlsFingerprint: fingerprint)
        try receiver.receive(.control(.init(type: .transferOffer, payload: .manifest(manifest))))
        return receiver
    }
    func sendFile(_ index: Int, bytes: String, manifest: TransferManifest, receiver: inout ReceiveProtocol) throws {
        let ref = FileReference(transferID: manifest.transferID, index: index)
        try receiver.receive(.control(.init(type: .fileBegin, payload: .file(ref))))
        try receiver.receive(.binary(Data(bytes.utf8)))
        try receiver.receive(.control(.init(type: .fileComplete, payload: .file(ref))))
    }
    func testValidSequenceRequiresLocalAcceptanceAndFinalization() throws {
        let manifest = fixtureManifest(); var receiver = try offered(manifest)
        XCTAssertEqual(receiver.state, .offered); _ = try receiver.accept()
        try sendFile(0, bytes: "{}", manifest: manifest, receiver: &receiver)
        try sendFile(1, bytes: "abc", manifest: manifest, receiver: &receiver)
        XCTAssertEqual(receiver.state, .finalizing); XCTAssertEqual(receiver.receivedBytes, 5)
        let projectID = UUID(); let result = try receiver.finalized(projectID: projectID)
        XCTAssertEqual(result.projectID, projectID); XCTAssertEqual(result.manifestDigest, try manifest.digest())
        XCTAssertEqual(receiver.state, .completed)
    }
    func testUnpairedCannotOfferAndJSONCannotAuthorize() throws {
        var receiver = ReceiveProtocol(); try receiver.receive(hello())
        XCTAssertThrowsError(try receiver.receive(.control(.init(type: .transferOffer, payload: .manifest(fixtureManifest())))))
        XCTAssertEqual(receiver.state, .failed)
        var forged = ReceiveProtocol(); try forged.receive(hello())
        XCTAssertThrowsError(try forged.receive(.control(.init(type: .pairingConfirmation, payload: .confirmation(.init(transcriptDigest: fingerprint))))))
    }
    func testTLSFingerprintMustMatchHello() throws {
        var receiver = ReceiveProtocol(); try receiver.receive(hello())
        XCTAssertThrowsError(try receiver.authorizePeer(tlsFingerprint: String(repeating: "c", count: 64)))
        XCTAssertEqual(receiver.state, .failed)
    }
    func testUnexpectedOrderingAndUnacceptedBinary() throws {
        var fresh = ReceiveProtocol(); XCTAssertThrowsError(try fresh.receive(.binary(Data([1]))))
        var offered = try offered(fixtureManifest()); XCTAssertThrowsError(try offered.receive(.binary(Data([1]))))
        var repeated = ReceiveProtocol(); try repeated.receive(hello()); XCTAssertThrowsError(try repeated.receive(hello()))
    }
    func testInvalidFileIDIndexAndDuplicateCannotStart() throws {
        let manifest = fixtureManifest()
        for reference in [FileReference(transferID: UUID(), index: 0), FileReference(transferID: manifest.transferID, index: 9)] {
            var receiver = try offered(manifest); _ = try receiver.accept()
            XCTAssertThrowsError(try receiver.receive(.control(.init(type: .fileBegin, payload: .file(reference)))))
        }
        var receiver = try offered(manifest); _ = try receiver.accept(reverifiedIndices: [0])
        XCTAssertThrowsError(try receiver.receive(.control(.init(type: .fileBegin, payload: .file(.init(transferID: manifest.transferID, index: 0))))))
    }
    func testTruncatedOrCorruptFileNeverVerified() throws {
        let manifest = fixtureManifest()
        for bytes in ["a", "xyz"] {
            var receiver = try offered(manifest); _ = try receiver.accept()
            XCTAssertThrowsError(try sendFile(1, bytes: bytes, manifest: manifest, receiver: &receiver))
            XCTAssertFalse(receiver.verifiedIndices.contains(1)); XCTAssertEqual(receiver.state, .failed)
        }
    }
    func testResumeRequiresMatchingManifestAndReverification() throws {
        let manifest = fixtureManifest()
        let journal = try ResumeDescriptor(manifest: manifest, verifiedIndices: [0])
        let decoded = try JSONDecoder().decode(ResumeDescriptor.self, from: JSONEncoder().encode(journal))
        XCTAssertEqual(try decoded.candidates(for: manifest), [0])
        XCTAssertEqual(try decoded.candidates(for: fixtureManifest()), [])
        XCTAssertEqual(try decoded.candidates(for: fixtureManifest(name: "Renamed", id: manifest.transferID)), [])
        var receiver = try offered(manifest)
        let accepted = try receiver.accept(reverifiedIndices: [0])
        XCTAssertEqual(accepted.verifiedFileIndices, [0]); XCTAssertEqual(receiver.receivedBytes, 2)
        try sendFile(1, bytes: "abc", manifest: manifest, receiver: &receiver)
        XCTAssertEqual(receiver.state, .finalizing)
    }
    func testUnverifiedResumeCandidateMustBeResent() throws {
        var receiver = try offered(fixtureManifest())
        _ = try receiver.accept(reverifiedIndices: [])
        XCTAssertEqual(receiver.verifiedIndices, []); XCTAssertEqual(receiver.receivedBytes, 0)
    }
    func testCancelAndTimeoutPreserveOnlyVerifiedIndices() throws {
        let manifest = fixtureManifest()
        for interrupted in [false, true] {
            var receiver = try offered(manifest); _ = try receiver.accept()
            try sendFile(0, bytes: "{}", manifest: manifest, receiver: &receiver)
            try receiver.receive(.control(.init(type: .fileBegin, payload: .file(.init(transferID: manifest.transferID, index: 1)))))
            try receiver.receive(.binary(Data("a".utf8)))
            if interrupted { receiver.interrupt() } else { receiver.cancel() }
            XCTAssertEqual(receiver.verifiedIndices, [0])
            XCTAssertEqual(receiver.state, interrupted ? .interrupted : .cancelled)
            XCTAssertThrowsError(try receiver.receive(.binary(Data("bc".utf8))))
        }
    }
    func testDeclineReturnsToIdleAndPeerCannotDeclareCompletion() throws {
        var receiver = try offered(fixtureManifest()); try receiver.decline(); XCTAssertEqual(receiver.state, .idle)
        let manifest = fixtureManifest(); var forged = try offered(manifest); _ = try forged.accept()
        XCTAssertThrowsError(try forged.receive(.control(.init(type: .transferComplete, payload: .completion(.init(transferID: manifest.transferID, projectID: UUID(), manifestDigest: try manifest.digest()))))))
    }
}
