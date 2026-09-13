import XCTest
import Caliper3DCore
@testable import Caliper3DTransfer

final class IncomingStoreTests: XCTestCase {
    func fixture(_ root: URL) async throws -> PreparedCaptureTransfer {
        let repository = LocalCaptureRepository(root: root.appendingPathComponent("Phone"), sourceDevice: .init(name: "Test iPhone", operatingSystem: "Test OS", objectCaptureSupported: true))
        let allocation = try await repository.allocate(name: "Synthetic Mouse")
        try Data([1,2,3,4]).write(to: allocation.images.appendingPathComponent("a.heic"))
        try Data([5,6]).write(to: allocation.checkpoints.appendingPathComponent("pointcloud"))
        _ = try await repository.complete(allocation.id)
        return try await PreparedCaptureTransfer.prepare(captureID: allocation.id, repository: repository)
    }
    func send(_ prepared: PreparedCaptureTransfer, index: Int, store: IncomingCaptureStore) async throws {
        let reference = FileReference(transferID: prepared.manifest.transferID, index: index)
        try await store.begin(reference)
        var offset: Int64 = 0
        while offset < prepared.manifest.files[index].bytes {
            let data = try await prepared.source.read(fileIndex: index, offset: offset, count: TransferPolicy.chunkBytes)
            try await store.append(data); offset += Int64(data.count)
        }
        try await store.complete(reference)
    }
    func testReceiveFinalizeReopenDuplicateAndOriginalPreserved() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let prepared = try await fixture(root)
        let projects = LocalProjectStore(root: root.appendingPathComponent("Projects"))
        let store = IncomingCaptureStore(root: root.appendingPathComponent("Incoming"), projects: projects)
        let skipped = try await store.prepare(prepared.manifest); XCTAssertTrue(skipped.isEmpty)
        for index in prepared.manifest.files.indices { try await send(prepared, index: index, store: store) }
        let result = try await store.finish()
        guard case .created(let project) = result else { return XCTFail() }
        XCTAssertEqual(project.id, prepared.manifest.captureID)
        XCTAssertEqual(project.manifest.captureMethod, .objectCapture)
        XCTAssertEqual(project.manifest.reconstructionState, .notStarted)
        XCTAssertEqual(project.manifest.sourceDevice?.name, "Test iPhone")
        let library = try await projects.list(); XCTAssertEqual(library.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: project.url.appendingPathComponent("capture/Images/a.heic").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Incoming/\(prepared.manifest.transferID.uuidString).partial").path))
        _ = try await prepared.source.describe() // original phone source still intact
        _ = try await store.prepare(prepared.manifest)
        for index in prepared.manifest.files.indices { try await send(prepared, index: index, store: store) }
        guard case .duplicate = try await store.finish() else { return XCTFail("Identical dataset must not create another project") }
    }
    func testRelaunchRehashesJournalAndRestartsUnverifiedFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let prepared = try await fixture(root)
        let projects = LocalProjectStore(root: root.appendingPathComponent("Projects"))
        let incoming = root.appendingPathComponent("Incoming")
        let store = IncomingCaptureStore(root: incoming, projects: projects)
        _ = try await store.prepare(prepared.manifest)
        try await send(prepared, index: 0, store: store)
        try await store.begin(.init(transferID: prepared.manifest.transferID, index: 1)); try await store.append(Data([1]))
        try await store.cancel()
        let relaunched = IncomingCaptureStore(root: incoming, projects: projects)
        var skipped = try await relaunched.prepare(prepared.manifest); XCTAssertEqual(skipped, [0])
        try await relaunched.cancel()
        let verifiedFile = incoming.appendingPathComponent(prepared.manifest.transferID.uuidString + ".partial/dataset/" + prepared.manifest.files[0].path)
        try Data([255]).write(to: verifiedFile)
        skipped = try await relaunched.prepare(prepared.manifest); XCTAssertTrue(skipped.isEmpty)
        for index in prepared.manifest.files.indices { try await send(prepared, index: index, store: relaunched) }
        _ = try await relaunched.finish()
    }
    func testCorruptionAndExtraBytesNeverBecomeVerified() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let prepared = try await fixture(root)
        let store = IncomingCaptureStore(root: root.appendingPathComponent("Incoming"), projects: LocalProjectStore(root: root.appendingPathComponent("Projects")))
        _ = try await store.prepare(prepared.manifest)
        let reference = FileReference(transferID: prepared.manifest.transferID, index: 0)
        try await store.begin(reference)
        do { try await store.append(Data(count: Int(prepared.manifest.files[0].bytes) + 1)); XCTFail() } catch { }
        try await store.cancel()
        let skipped = try await store.prepare(prepared.manifest); XCTAssertTrue(skipped.isEmpty)
        try await store.begin(reference)
        try await store.append(Data(repeating: 255, count: Int(prepared.manifest.files[0].bytes)))
        do { try await store.complete(reference); XCTFail() } catch { }
        do { _ = try await store.finish(); XCTFail() } catch { }
    }
    func testSymlinkInExistingPartialCannotBeFollowedOrDeletedOnRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let prepared = try await fixture(root)
        let incoming = root.appendingPathComponent("Incoming")
        let store = IncomingCaptureStore(root: incoming, projects: LocalProjectStore(root: root.appendingPathComponent("Projects")))
        _ = try await store.prepare(prepared.manifest); try await store.cancel()
        let outside = root.appendingPathComponent("Preserved")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent("sentinel")
        try Data([42]).write(to: sentinel)
        let link = incoming.appendingPathComponent(prepared.manifest.transferID.uuidString + ".partial/dataset/Images/link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        do { _ = try await store.prepare(prepared.manifest); XCTFail() } catch { }
        XCTAssertEqual(try Data(contentsOf: sentinel), Data([42]))
    }
    func testLowDiskAndUnsafeRootFailWithoutExternalWrite() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let prepared = try await fixture(root)
        let projects = LocalProjectStore(root: root.appendingPathComponent("Projects"))
        let low = IncomingCaptureStore(root: root.appendingPathComponent("Incoming"), projects: projects, availableBytes: { _ in 0 })
        do { _ = try await low.prepare(prepared.manifest); XCTFail() } catch { XCTAssertTrue(error is IncomingCaptureError) }
        let target = root.appendingPathComponent("Outside")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("Link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let unsafe = IncomingCaptureStore(root: link.appendingPathComponent("Incoming"), projects: projects)
        do { _ = try await unsafe.prepare(prepared.manifest); XCTFail() } catch { }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    }
    func testChangedManifestRestartsStagingAndExistingProjectConflicts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let prepared = try await fixture(root)
        let projects = LocalProjectStore(root: root.appendingPathComponent("Projects"))
        let store = IncomingCaptureStore(root: root.appendingPathComponent("Incoming"), projects: projects)
        _ = try await store.prepare(prepared.manifest); try await send(prepared, index: 0, store: store); try await store.cancel()
        let old = prepared.manifest
        let changed = TransferManifest(transferID: old.transferID, captureID: old.captureID, name: "Changed", createdAt: old.createdAt, source: old.source, imageCount: old.imageCount, totalBytes: old.totalBytes, files: old.files)
        let skipped = try await store.prepare(changed); XCTAssertTrue(skipped.isEmpty)
        try await store.cancel()
        _ = try await projects.create(ScanManifest(id: old.captureID, name: "Existing", captureMethod: .demo))
        _ = try await store.prepare(old)
        for index in old.files.indices { try await send(prepared, index: index, store: store) }
        do { _ = try await store.finish(); XCTFail() } catch { XCTAssertTrue(error is ReceivedProjectError) }
        let library = try await projects.list(); XCTAssertEqual(library.count, 1); XCTAssertEqual(library[0].manifest.name, "Existing")
    }
}
