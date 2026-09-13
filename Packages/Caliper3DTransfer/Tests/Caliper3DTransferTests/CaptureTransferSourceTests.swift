import XCTest
import Caliper3DCore
@testable import Caliper3DTransfer

final class CaptureTransferSourceTests: XCTestCase {
    func testLegacyCaptureHasExplicitlyUnknownDeviceAndStableResumeIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = LocalCaptureRepository(root: root)
        let allocation = try await repository.allocate(name: "Synthetic capture")
        try Data([1,2,3]).write(to: allocation.images.appendingPathComponent("a.heic"))
        let record = try await repository.complete(allocation.id)
        let first = try await PreparedCaptureTransfer.prepare(captureID: record.id, repository: repository)
        let second = try await PreparedCaptureTransfer.prepare(captureID: record.id, repository: repository)
        XCTAssertEqual(first.manifest, second.manifest)
        XCTAssertEqual(first.manifest.transferID, record.id)
        XCTAssertNil(first.manifest.source.objectCaptureSupported)
        XCTAssertEqual(first.manifest.source.operatingSystem, "Not recorded")
        XCTAssertGreaterThan(first.manifest.totalBytes, try XCTUnwrap(record.totalBytes)) // includes capture.json
        try first.manifest.validate()
    }
    func testRecordedDeviceMetadataSurvivesPreparation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = LocalCaptureRepository(root: root, sourceDevice: .init(name: "Recorded iPhone", operatingSystem: "Recorded OS", objectCaptureSupported: true))
        let allocation = try await repository.allocate(name: "Synthetic capture")
        try Data([1]).write(to: allocation.images.appendingPathComponent("a.heic"))
        _ = try await repository.complete(allocation.id)
        let prepared = try await PreparedCaptureTransfer.prepare(captureID: allocation.id, repository: repository)
        XCTAssertEqual(prepared.manifest.source.name, "Recorded iPhone")
        XCTAssertEqual(prepared.manifest.source.operatingSystem, "Recorded OS")
        XCTAssertEqual(prepared.manifest.source.objectCaptureSupported, true)
    }
}
