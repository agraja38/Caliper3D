import XCTest
import CryptoKit
@testable import Caliper3DCore

final class CaptureSourceTests: XCTestCase {
    func testReadyDatasetIsHashedAndReadByIndexWithoutURLs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let device = CaptureSourceDevice(name: "Test", operatingSystem: "iOS", objectCaptureSupported: true)
        let repo = LocalCaptureRepository(root: root, sourceDevice: device)
        let allocation = try await repo.allocate(name: "Test")
        let image = Data(repeating: 7, count: CaptureSourceLimits.chunkBytes + 10)
        try image.write(to: allocation.images.appendingPathComponent("a.heic"))
        let subfolder = allocation.checkpoints.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: false)
        try Data([1,2,3]).write(to: subfolder.appendingPathComponent("data"))
        _ = try await repo.complete(allocation.id)
        let source = try await repo.prepareSource(allocation.id)
        let description = try await source.describe()
        XCTAssertEqual(description.record.sourceDevice, device)
        XCTAssertEqual(Set(description.files.map(\.path)), ["capture.json", "Images/a.heic", "Checkpoints/nested/data"])
        let index = try XCTUnwrap(description.files.firstIndex { $0.path == "Images/a.heic" })
        XCTAssertEqual(description.files[index].sha256, SHA256.hash(data: image).map { String(format: "%02x", $0) }.joined())
        let first = try await source.read(fileIndex: index, offset: 0, count: CaptureSourceLimits.chunkBytes)
        let second = try await source.read(fileIndex: index, offset: Int64(first.count), count: CaptureSourceLimits.chunkBytes)
        XCTAssertEqual(first + second, image)
        do { _ = try await source.read(fileIndex: index, offset: 0, count: CaptureSourceLimits.chunkBytes + 1); XCTFail() } catch { }
        do { _ = try await source.read(fileIndex: -1, offset: 0, count: 1); XCTFail() } catch { }
    }
    func testUnfinishedCaptureCannotIssueSource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = LocalCaptureRepository(root: root); let allocation = try await repo.allocate(name: "Incomplete")
        do { _ = try await repo.prepareSource(allocation.id); XCTFail() } catch { }
    }
    func testMetadataRenameAndFileReplacementInvalidatePreparedSource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = LocalCaptureRepository(root: root); let allocation = try await repo.allocate(name: "Test")
        let url = allocation.images.appendingPathComponent("a.heic")
        try Data([1,2,3]).write(to: url); _ = try await repo.complete(allocation.id)
        let source = try await repo.prepareSource(allocation.id); let description = try await source.describe()
        let index = try XCTUnwrap(description.files.firstIndex { $0.path == "Images/a.heic" })
        try Data([4,5,6]).write(to: url, options: .atomic)
        do { _ = try await source.read(fileIndex: index, offset: 0, count: 3); XCTFail() } catch { }
        let sourceBeforeRename = try await repo.prepareSource(allocation.id)
        _ = try await repo.rename(allocation.id, name: "Changed")
        do { _ = try await sourceBeforeRename.describe(); XCTFail() } catch { }
    }
    func testUnexpectedRootAndSymlinkAreRejected() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = LocalCaptureRepository(root: root); let allocation = try await repo.allocate(name: "Test")
        let image = allocation.images.appendingPathComponent("a.heic")
        try Data([1]).write(to: image); _ = try await repo.complete(allocation.id)
        let source = try await repo.prepareSource(allocation.id)
        try FileManager.default.removeItem(at: image)
        try FileManager.default.createSymbolicLink(at: image, withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        do { _ = try await source.describe(); XCTFail() } catch { }
    }
}
