import XCTest
@testable import Caliper3DTransfer

final class PairingTests: XCTestCase {
    let phone = String(repeating: "a", count: 64), mac = String(repeating: "b", count: 64)
    let now = Date(timeIntervalSince1970: 1_000)
    func pair(exporter: UInt8 = 7, role: PairingSession.Role) throws -> PairingSession {
        try PairingSession(role: role, phoneFingerprint: phone, macFingerprint: mac,
            tlsPeerFingerprint: role == .phone ? mac : phone, tlsExporter: Data(repeating: exporter, count: 32),
            nonce: Data(repeating: role == .phone ? 1 : 2, count: 32), now: now)
    }
    func exchange(_ a: inout PairingSession, _ b: inout PairingSession) throws {
        let ac = a.commitment, bc = b.commitment
        try a.receiveCommitment(bc, now: now); try b.receiveCommitment(ac, now: now)
        let ar = try a.reveal(now: now), br = try b.reveal(now: now)
        try a.receiveReveal(br, now: now); try b.receiveReveal(ar, now: now)
    }
    func testPairingMessagesRoundTripAndRejectMalformedValues() throws {
        let value = String(repeating: "a", count: 64)
        for message in [ControlMessage(type: .pairingCommitment, payload: .commitment(.init(sha256: value))),
                        ControlMessage(type: .pairingReveal, payload: .reveal(.init(nonce: value))),
                        ControlMessage(type: .pairingConfirmation, payload: .confirmation(.init(transcriptDigest: value)))] {
            var decoder = FrameDecoder()
            XCTAssertEqual(try decoder.append(WireFrame.control(message).encoded()), [.control(message)])
        }
        XCTAssertThrowsError(try ControlMessage(type: .pairingReveal, payload: .reveal(.init(nonce: "bad"))).validate())
    }
    func testMatchingCodeRequiresBothExplicitConfirmations() throws {
        var a = try pair(role: .phone), b = try pair(role: .mac)
        try exchange(&a, &b)
        XCTAssertEqual(a.verificationCode, b.verificationCode)
        XCTAssertEqual(a.verificationCode?.count, 7)
        let first = try a.confirmLocally(now: now)
        try b.receiveConfirmation(first, now: now)
        XCTAssertEqual(a.state, .awaitingConfirmation); XCTAssertEqual(b.state, .awaitingConfirmation)
        let second = try b.confirmLocally(now: now); try a.receiveConfirmation(second, now: now)
        XCTAssertEqual(a.state, .approved); XCTAssertEqual(b.state, .approved)
    }
    func testDifferentTLSExportersCannotConfirmEachOther() throws {
        var a = try pair(role: .phone), b = try pair(exporter: 8, role: .mac)
        try exchange(&a, &b)
        let confirmation = try a.confirmLocally(now: now)
        XCTAssertThrowsError(try b.receiveConfirmation(confirmation, now: now))
        XCTAssertEqual(b.state, .rejected)
    }
    func testFingerprintMismatchRejectsConstruction() {
        XCTAssertThrowsError(try PairingSession(role: .phone, phoneFingerprint: phone, macFingerprint: mac,
            tlsPeerFingerprint: phone, tlsExporter: Data(count: 32), now: now))
    }
    func testRevealBeforeCommitAndChangedNonceFailClosed() throws {
        var a = try pair(role: .phone)
        XCTAssertThrowsError(try a.reveal(now: now)); XCTAssertEqual(a.state, .rejected)
        var b = try pair(role: .phone); let peer = try pair(role: .mac)
        try b.receiveCommitment(peer.commitment, now: now)
        XCTAssertThrowsError(try b.receiveReveal(String(repeating: "f", count: 64), now: now))
        XCTAssertEqual(b.state, .rejected)
    }
    func testExpiryAndRejectionPreventTrust() throws {
        var a = try pair(role: .phone), b = try pair(role: .mac)
        try exchange(&a, &b)
        XCTAssertThrowsError(try a.confirmLocally(now: now.addingTimeInterval(120)))
        b.reject(); XCTAssertNil(b.verificationCode)
        XCTAssertThrowsError(try b.confirmLocally(now: now))
    }
    func testDuplicateCommitOrEarlyConfirmationRejected() throws {
        var a = try pair(role: .phone); let b = try pair(role: .mac)
        try a.receiveCommitment(b.commitment, now: now)
        XCTAssertThrowsError(try a.receiveCommitment(b.commitment, now: now))
        var c = try pair(role: .phone)
        XCTAssertThrowsError(try c.receiveConfirmation(String(repeating: "a", count: 64), now: now))
    }
}
