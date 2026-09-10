import XCTest
@testable import Caliper3DCore

final class CaptureRepositoryTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func testLegacyDemoDecodesWithoutPersistentFields() throws {
        let id = UUID()
        let data = Data("{\"id\":\"\(id)\",\"name\":\"Demo\",\"imageCount\":48,\"isDemo\":true}".utf8)
        let record = try JSONDecoder().decode(CaptureRecord.self, from: data)
        XCTAssertEqual(record.id, id); XCTAssertTrue(record.isDemo); XCTAssertNil(record.status)
        XCTAssertThrowsError(try record.validateReal())
    }
    func testRealMetadataRoundTrip() throws {
        let record = CaptureRecord(name: "Object", imageCount: 0, isDemo: false)
        try record.validateReal()
        XCTAssertEqual(try JSONDecoder().decode(CaptureRecord.self, from: JSONEncoder().encode(record)), record)
    }
    func testUniqueEmptyAllocationAndIncompleteRecovery() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = LocalCaptureRepository(root: root)
        let first = try await repo.allocate(name: "../../Name")
        let second = try await repo.allocate(name: "../../Name")
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.images.deletingLastPathComponent().lastPathComponent, first.id.uuidString)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: first.images.path), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: first.checkpoints.path), [])
        let library = try await LocalCaptureRepository(root: root).library()
        XCTAssertEqual(library.incomplete.count, 2); XCTAssertTrue(library.completed.isEmpty)
    }
    func testCompletionCountsFilesAndBytesAndRelaunch() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = LocalCaptureRepository(root: root)
        let capture = try await repo.allocate(name: "Object")
        try Data(repeating: 1, count: 10).write(to: capture.images.appendingPathComponent("IMG_001.HEIC"))
        try Data(repeating: 2, count: 20).write(to: capture.images.appendingPathComponent("IMG_002.JPG"))
        try Data().write(to: capture.images.appendingPathComponent("empty.heic"))
        try Data(repeating: 3, count: 5).write(to: capture.checkpoints.appendingPathComponent("checkpoint.bin"))
        let record = try await repo.complete(capture.id)
        XCTAssertEqual(record.imageCount, 2); XCTAssertEqual(record.totalBytes, 35); XCTAssertEqual(record.status, .ready)
        let recovered = try await LocalCaptureRepository(root: root).library()
        XCTAssertEqual(recovered.completed.map(\.id), [capture.id])
        do { _ = try await repo.complete(capture.id); XCTFail("Cannot overwrite completed capture") }
        catch { XCTAssertEqual(error as? CaptureStorageError, .alreadyCompleted) }
    }
    func testNoImagesCannotBecomeReady() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = LocalCaptureRepository(root: root)
        let capture = try await repo.allocate(name: "Empty")
        do { _ = try await repo.complete(capture.id); XCTFail() }
        catch { XCTAssertEqual(error as? CaptureStorageError, .noImages) }
        let library = try await repo.library(); XCTAssertTrue(library.completed.isEmpty)
    }
    func testRenameChangesOnlyMetadata() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = LocalCaptureRepository(root: root)
        let capture = try await repo.allocate(name: "Original")
        let renamed = try await repo.rename(capture.id, name: "  ../Teapot  ")
        XCTAssertEqual(renamed.name, "../Teapot")
        XCTAssertTrue(FileManager.default.fileExists(atPath: capture.images.path))
        for name in ["", "\n", String(repeating: "a", count: 121)] {
            do { _ = try await repo.rename(capture.id, name: name); XCTFail() }
            catch { XCTAssertEqual(error as? CaptureStorageError, .invalidName) }
        }
    }
    func testDeleteOnlyIntendedCapture() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = LocalCaptureRepository(root: root)
        let first = try await repo.allocate(name: "First"), second = try await repo.allocate(name: "Second")
        try await repo.delete(first.id)
        let library = try await repo.library()
        XCTAssertEqual(library.incomplete.map(\.id), [second.id])
    }
    func testSymlinkDatasetCannotBeCountedOrDeleted() async throws {
        let root = try directory(), outside = try directory()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let repo = LocalCaptureRepository(root: root)
        let capture = try await repo.allocate(name: "Unsafe")
        let sentinel = outside.appendingPathComponent("photo.heic")
        try Data([1, 2]).write(to: sentinel)
        try FileManager.default.createSymbolicLink(at: capture.images.appendingPathComponent("escape.heic"), withDestinationURL: sentinel)
        do { _ = try await repo.complete(capture.id); XCTFail() }
        catch { XCTAssertEqual(error as? CaptureStorageError, .unsafePath) }
        do { try await repo.delete(capture.id); XCTFail() }
        catch { XCTAssertEqual(error as? CaptureStorageError, .unsafePath) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
    }
    func testSymlinkCaptureRootRejected() async throws {
        let parent = try directory(), outside = try directory()
        defer { try? FileManager.default.removeItem(at: parent); try? FileManager.default.removeItem(at: outside) }
        let link = parent.appendingPathComponent("Captures")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        do { _ = try await LocalCaptureRepository(root: link).allocate(name: "Scan"); XCTFail() }
        catch { XCTAssertEqual(error as? CaptureStorageError, .unsafePath) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    }
    func testCorruptMetadataDoesNotHideOtherCapturesOrDeleteData() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = LocalCaptureRepository(root: root)
        let broken = try await repo.allocate(name: "Broken"), good = try await repo.allocate(name: "Good")
        try Data("bad json".utf8).write(to: broken.images.deletingLastPathComponent().appendingPathComponent("capture.json"))
        let library = try await repo.library()
        XCTAssertEqual(library.unreadableCount, 1); XCTAssertEqual(library.incomplete.map(\.id), [good.id])
        do { try await repo.delete(broken.id); XCTFail() } catch { }
        XCTAssertTrue(FileManager.default.fileExists(atPath: broken.images.path))
    }
    func testLowStorageDoesNotAllocateScan() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = LocalCaptureRepository(root: root, availableBytes: { _ in 1 })
        do { _ = try await repo.allocate(name: "Low disk"); XCTFail() }
        catch { XCTAssertEqual(error as? CaptureStorageError, .insufficientSpace) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }
    func testCancelledCaptureIsPreservedAcrossLaunch() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = LocalCaptureRepository(root: root)
        let capture = try await repo.allocate(name: "Interrupted")
        let image = capture.images.appendingPathComponent("a.heic"); try Data([1]).write(to: image)
        try await repo.markIncomplete(capture.id, failed: false)
        let library = try await LocalCaptureRepository(root: root).library()
        XCTAssertEqual(library.incomplete.first?.status, .interrupted)
        XCTAssertTrue(FileManager.default.fileExists(atPath: image.path))
    }
}
