import XCTest
import Security
@testable import Caliper3DTransfer

final class IdentityTrustTests: XCTestCase {
    func testGeneratedCertificateAndPrivateKeyFormValidSecurityIdentity() throws {
        let now = Date()
        let material = try IdentityCertificate.createMaterial(now: now)
        let identity = try LocalTLSIdentity(material: material)
        let reload = try LocalTLSIdentity(material: material)
        XCTAssertEqual(identity.fingerprint, reload.fingerprint)
        XCTAssertEqual(identity.fingerprint.count, 64)
        var trust: SecTrust?
        XCTAssertEqual(SecTrustCreateWithCertificates(identity.certificate, SecPolicyCreateBasicX509(), &trust), errSecSuccess)
        let checked = try XCTUnwrap(trust)
        XCTAssertEqual(SecTrustSetAnchorCertificates(checked, [identity.certificate] as CFArray), errSecSuccess)
        XCTAssertEqual(SecTrustSetAnchorCertificatesOnly(checked, true), errSecSuccess)
        XCTAssertEqual(SecTrustSetVerifyDate(checked, now as CFDate), errSecSuccess)
        XCTAssertTrue(SecTrustEvaluateWithError(checked, nil))
        var key: SecKey?
        XCTAssertEqual(SecIdentityCopyPrivateKey(identity.identity, &key), errSecSuccess)
        let privateKey = try XCTUnwrap(key)
        let publicKey = try XCTUnwrap(SecCertificateCopyKey(identity.certificate))
        let data = Data("identity proof".utf8)
        let signature = try XCTUnwrap(SecKeyCreateSignature(privateKey, .ecdsaSignatureMessageX962SHA256, data as CFData, nil))
        XCTAssertTrue(SecKeyVerifySignature(publicKey, .ecdsaSignatureMessageX962SHA256, data as CFData, signature, nil))
    }
    func testIdentitiesAreUniqueAndCorruptMaterialRejected() throws {
        let first = try LocalTLSIdentity(material: IdentityCertificate.createMaterial())
        let second = try LocalTLSIdentity(material: IdentityCertificate.createMaterial())
        XCTAssertNotEqual(first.fingerprint, second.fingerprint)
        XCTAssertThrowsError(try LocalTLSIdentity(material: Data("{}".utf8)))
        XCTAssertThrowsError(try LocalTLSIdentity(material: Data(count: 32_769)))
    }
    func testTrustRequiresPairingSurvivesSerializationAndForgetRevokes() throws {
        let phoneFingerprint = String(repeating: "a", count: 64), macFingerprint = String(repeating: "b", count: 64)
        var phone = try PairingSession(role: .phone, phoneFingerprint: phoneFingerprint, macFingerprint: macFingerprint,
            tlsPeerFingerprint: macFingerprint, tlsExporter: Data(repeating: 4, count: 32))
        var mac = try PairingSession(role: .mac, phoneFingerprint: phoneFingerprint, macFingerprint: macFingerprint,
            tlsPeerFingerprint: phoneFingerprint, tlsExporter: Data(repeating: 4, count: 32))
        var trust = TrustRecords()
        XCTAssertThrowsError(try trust.approve(phone, name: "Mac"))
        let pc = phone.commitment, mc = mac.commitment
        try phone.receiveCommitment(mc); try mac.receiveCommitment(pc)
        let pr = try phone.reveal(), mr = try mac.reveal()
        try phone.receiveReveal(mr); try mac.receiveReveal(pr)
        let confirmation = try phone.confirmLocally(); try mac.receiveConfirmation(confirmation)
        try phone.receiveConfirmation(mac.confirmLocally())
        try trust.approve(phone, name: "Mac")
        var reloaded = try JSONDecoder().decode(TrustRecords.self, from: JSONEncoder().encode(trust))
        try reloaded.requirePinned(expected: macFingerprint, presented: macFingerprint)
        XCTAssertThrowsError(try reloaded.requirePinned(expected: macFingerprint, presented: phoneFingerprint))
        reloaded.forget(macFingerprint)
        XCTAssertThrowsError(try reloaded.requirePinned(expected: macFingerprint, presented: macFingerprint))
    }
}
