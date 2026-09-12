import XCTest
@testable import Caliper3DTransfer

final class WireProtocolTests: XCTestCase {
    let ping = WireFrame.control(ControlMessage(type: .ping, payload: .empty))
    func raw(_ json: String) -> Data {
        let body = Data(json.utf8); let n = UInt32(body.count)
        return Data([1, UInt8(n >> 24), UInt8((n >> 16) & 255), UInt8((n >> 8) & 255), UInt8(n & 255)]) + body
    }
    func testNormalAndEverySplitBoundary() throws {
        let bytes = try ping.encoded()
        for split in 0...bytes.count {
            var decoder = FrameDecoder()
            let a = try decoder.append(Data(bytes.prefix(split)))
            let b = try decoder.append(Data(bytes.dropFirst(split)))
            XCTAssertEqual(a + b, [ping]); try decoder.finish()
        }
    }
    func testByteAtATimeAndConcatenatedFrames() throws {
        let binary = WireFrame.binary(Data([0, 255, 1]))
        let bytes = try ping.encoded() + binary.encoded() + ping.encoded()
        var decoder = FrameDecoder(); var received: [WireFrame] = []
        for byte in bytes { received += try decoder.append(Data([byte])) }
        XCTAssertEqual(received, [ping, binary, ping]); try decoder.finish()
        var combined = FrameDecoder(); XCTAssertEqual(try combined.append(bytes), received)
    }
    func testManyCoalescedFramesAndTrailingPartial() throws {
        let encoded = try ping.encoded()
        var bytes = Data()
        for _ in 0..<1000 { bytes.append(encoded) }
        bytes.append(encoded.prefix(3))
        var decoder = FrameDecoder()
        XCTAssertEqual(try decoder.append(bytes), Array(repeating: ping, count: 1000))
        XCTAssertEqual(try decoder.append(Data(encoded.dropFirst(3))), [ping])
        try decoder.finish()
    }
    func testZeroUnknownAndOversizeHeaderRejectedImmediately() {
        for header: [UInt8] in [[1,0,0,0,0], [2,0,0,0,0], [3,0,0,0,1], [1,255,255,255,255], [2,0,4,0,1]] {
            var decoder = FrameDecoder()
            XCTAssertThrowsError(try decoder.append(Data(header)))
            XCTAssertThrowsError(try decoder.append(Data())) // cannot recover a poisoned stream
        }
    }
    func testMalformedJSONAndUnknownType() {
        for json in ["{", "[]", "{}", "{\"version\":1,\"type\":\"unknown\"}", "{\"version\":1,\"type\":\"ping\",\"payload\":{}}"] {
            var decoder = FrameDecoder(); XCTAssertThrowsError(try decoder.append(raw(json)))
        }
    }
    func testUnsupportedVersionBeforePayloadDecode() {
        var decoder = FrameDecoder()
        XCTAssertThrowsError(try decoder.append(raw("{\"version\":42}"))) { XCTAssertEqual($0 as? WireError, .unsupportedVersion(42)) }
    }
    func testTruncationAtEveryBoundary() throws {
        let bytes = try ping.encoded()
        for count in 1..<bytes.count {
            var decoder = FrameDecoder(); _ = try decoder.append(Data(bytes.prefix(count)))
            XCTAssertThrowsError(try decoder.finish())
        }
    }
    func testReceiveAndBinaryAllocationBounds() throws {
        var decoder = FrameDecoder()
        XCTAssertThrowsError(try decoder.append(Data(count: TransferPolicy.receiveBytes + 1)))
        XCTAssertThrowsError(try WireFrame.binary(Data()).encoded())
        XCTAssertThrowsError(try WireFrame.binary(Data(count: TransferPolicy.chunkBytes + 1)).encoded())
        let frame = WireFrame.binary(Data(repeating: 37, count: TransferPolicy.chunkBytes))
        let encoded = try frame.encoded(); var valid = FrameDecoder()
        XCTAssertEqual(try valid.append(Data(encoded.prefix(TransferPolicy.receiveBytes))), [])
        XCTAssertEqual(try valid.append(Data(encoded.dropFirst(TransferPolicy.receiveBytes))), [frame])
    }
    func testWrongPayloadCannotEncode() {
        XCTAssertThrowsError(try WireFrame.control(.init(type: .hello, payload: .empty)).encoded())
    }
    func testJSONShapeIsStable() throws {
        XCTAssertEqual(String(data: try ping.encoded().dropFirst(5), encoding: .utf8), "{\"type\":\"ping\",\"version\":1}")
    }
}

func fixtureManifest(files: [TransferFile]? = nil, total: Int64? = nil, name: String = "Mouse", id: UUID = UUID()) -> TransferManifest {
    let files = files ?? [TransferFile(path: "capture.json", bytes: 2, sha256: TransferPolicy.digest(Data("{}".utf8))),
                          TransferFile(path: "Images/IMG_0001.HEIC", bytes: 3, sha256: TransferPolicy.digest(Data("abc".utf8)))]
    return TransferManifest(transferID: id, captureID: UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!, name: name,
        createdAt: "2026-09-11T00:00:00Z", source: TransferSource(name: "Test iPhone", operatingSystem: "iOS", objectCaptureSupported: true),
        imageCount: 1, totalBytes: total ?? files.reduce(0) { $0 + max(0, min($1.bytes, 1_000_000)) }, files: files)
}
final class TransferManifestTests: XCTestCase {
    func testValidManifestAndStableDigestRoundTrip() throws {
        let manifest = fixtureManifest(); try manifest.validate()
        let decoded = try JSONDecoder().decode(TransferManifest.self, from: manifest.canonicalData())
        XCTAssertEqual(decoded, manifest); XCTAssertEqual(try decoded.digest(), try manifest.digest())
        let frame = WireFrame.control(.init(type: .transferOffer, payload: .manifest(manifest)))
        var decoder = FrameDecoder(); XCTAssertEqual(try decoder.append(frame.encoded()), [frame])
    }
    func testHostilePaths() {
        for path in ["/a", "../a", "Images/../a", "Images/./a", "Images//a", "Images/a\\b", "Images/a:b", "Images/a\0b", "Images/%2e%2e/a", "Images/a\nb", "Images/e\u{301}.heic", "Images/a.", "Images/a ", "Images/" + String(repeating: "x", count: 256)] {
            XCTAssertFalse(TransferPolicy.isSafeRelativePath(path), path)
        }
    }
    func testDuplicatesCaseAliasesAndFileDirectoryCollisions() {
        for extra in ["Images/IMG_0001.HEIC", "Images/img_0001.heic", "Images/IMG_0001.HEIC/child"] {
            let files = fixtureManifest().files + [TransferFile(path: extra, bytes: 0, sha256: TransferPolicy.digest(Data()))]
            XCTAssertThrowsError(try fixtureManifest(files: files).validate())
        }
    }
    func testOnlyDatasetRootsAllowed() {
        let files = fixtureManifest().files + [TransferFile(path: "private/key", bytes: 0, sha256: TransferPolicy.digest(Data()))]
        XCTAssertThrowsError(try fixtureManifest(files: files).validate())
    }
    func testSizeLimitsAndTotalMismatch() {
        for bytes: Int64 in [-1, TransferPolicy.maximumFileBytes + 1, Int64.max] {
            let files = [fixtureManifest().files[0], TransferFile(path: "Images/a.heic", bytes: bytes, sha256: TransferPolicy.digest(Data()))]
            XCTAssertThrowsError(try fixtureManifest(files: files).validate())
        }
        XCTAssertThrowsError(try fixtureManifest(total: 6).validate())
        XCTAssertThrowsError(try fixtureManifest(total: Int64.max).validate())
    }
    func testTooManyFilesAndAggregateLimit() {
        let file = TransferFile(path: "Checkpoints/x", bytes: 0, sha256: TransferPolicy.digest(Data()))
        XCTAssertThrowsError(try fixtureManifest(files: Array(repeating: file, count: TransferPolicy.maximumFiles + 1)).validate())
        let files = fixtureManifest().files + (0..<9).map { TransferFile(path: "Checkpoints/\($0)", bytes: TransferPolicy.maximumFileBytes, sha256: file.sha256) }
        XCTAssertThrowsError(try fixtureManifest(files: files, total: TransferPolicy.maximumTotalBytes).validate())
    }
    func testMissingMetadataImageAndBadDigest() {
        XCTAssertThrowsError(try fixtureManifest(files: [fixtureManifest().files[1]]).validate())
        XCTAssertThrowsError(try fixtureManifest(files: [fixtureManifest().files[0]]).validate())
        let files = [fixtureManifest().files[0], TransferFile(path: "Images/a.heic", bytes: 3, sha256: "not-a-digest")]
        XCTAssertThrowsError(try fixtureManifest(files: files).validate())
    }
    func testEmptyCheckpointFileIsValid() throws {
        let files = fixtureManifest().files + [TransferFile(path: "Checkpoints/empty", bytes: 0, sha256: TransferPolicy.digest(Data()))]
        try fixtureManifest(files: files).validate()
    }
}
final class FileIntegrityTests: XCTestCase {
    let file = TransferFile(path: "Images/a.heic", bytes: 3, sha256: TransferPolicy.digest(Data("abc".utf8)))
    func testIncrementalKnownDigest() throws {
        var verifier = try FileIntegrityVerifier(file: file)
        for byte in "abc".utf8 { try verifier.consume(Data([byte])) }
        XCTAssertEqual(verifier.receivedBytes, 3); try verifier.finish()
        XCTAssertThrowsError(try verifier.finish()); XCTAssertThrowsError(try verifier.consume(Data()))
    }
    func testCorruptTruncatedAndExtraBytes() throws {
        for bytes in ["abd", "ab", "abcd"] {
            var verifier = try FileIntegrityVerifier(file: file)
            XCTAssertThrowsError(try { try verifier.consume(Data(bytes.utf8)); try verifier.finish() }())
        }
    }
    func testEmptyFileAndChunkBound() throws {
        var empty = try FileIntegrityVerifier(file: .init(path: "Checkpoints/empty", bytes: 0, sha256: TransferPolicy.digest(Data())))
        try empty.finish()
        var verifier = try FileIntegrityVerifier(file: .init(path: "Images/a", bytes: 1_000_000, sha256: file.sha256))
        XCTAssertThrowsError(try verifier.consume(Data(count: TransferPolicy.chunkBytes + 1)))
    }
}
