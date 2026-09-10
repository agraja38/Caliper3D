import XCTest
@testable import Caliper3DCore

final class CoreTests: XCTestCase {
    func testManifestRoundTrip() throws {
        var manifest = ScanManifest(name: "Teapot", captureMethod: .objectCapture, imageCount: 48,
                                    sourceDevice: SourceDevice(name: "Test device", operatingSystem: "iOS 17", hasLiDAR: true))
        manifest.createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        manifest.modifiedAt = manifest.createdAt
        manifest.dimensions = Dimensions(width: 10, height: 20, depth: 30)
        manifest.meshStatistics = MeshStatistics(vertices: 8, triangles: 12)
        XCTAssertEqual(try ManifestCodec.decode(ManifestCodec.encode(manifest)), manifest)
    }
    func testRejectsUnknownSchemaBeforePayload() {
        XCTAssertThrowsError(try ManifestCodec.decode(Data(#"{"schemaVersion":999}"#.utf8))) {
            XCTAssertEqual($0 as? ProjectError, .unsupportedSchema(999))
        }
    }
    func testRejectsInvalidValues() {
        var manifest = ScanManifest(name: "", captureMethod: .demo)
        XCTAssertThrowsError(try ManifestCodec.encode(manifest))
        manifest.name = "Valid"; manifest.imageCount = -1
        XCTAssertThrowsError(try ManifestCodec.encode(manifest))
        manifest.imageCount = 0; manifest.dimensions = Dimensions(width: -.infinity, height: 1, depth: 1)
        XCTAssertThrowsError(try ManifestCodec.encode(manifest))
    }
    func testRejectsMalformedJSON() { XCTAssertThrowsError(try ManifestCodec.decode(Data("invalid".utf8))) }
    func testPackagePersistenceAndDuplicateProtection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalProjectStore(root: root)
        let manifest = ScanManifest(name: "../../Untrusted name", captureMethod: .demo)
        let project = try await store.create(manifest)
        XCTAssertEqual(project.url.deletingLastPathComponent().path, root.path)
        let reopened = try await store.open(project.url)
        XCTAssertEqual(reopened.id, manifest.id)
        let projects = try await store.list()
        XCTAssertEqual(projects.count, 1)
        for directory in ["capture", "reconstruction", "processed", "thumbnails", "logs"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: project.url.appendingPathComponent(directory).path))
        }
        do { _ = try await store.create(manifest); XCTFail("Must not overwrite") } catch { }
        let remaining = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(remaining.count, 1, "Failed writes must clean staging")
    }
    func testImportPreservesOriginals() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.jpg")
        let bytes = Data([1, 2, 3]); try bytes.write(to: source)
        let store = LocalProjectStore(root: root.appendingPathComponent("library"))
        let project = try await store.importPhotos([source], name: "Import")
        XCTAssertEqual(project.manifest.imageCount, 1)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertEqual(try Data(contentsOf: project.url.appendingPathComponent("capture/00000.jpg")), bytes)
        do { _ = try await store.importPhotos([], name: "Empty"); XCTFail() }
        catch { XCTAssertEqual(error as? ProjectError, .tooManyImages) }
    }
    func testRejectsSymlinkManifest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalProjectStore(root: root)
        let project = try await store.create(ScanManifest(name: "Safe", captureMethod: .demo))
        let manifestURL = project.url.appendingPathComponent("manifest.json")
        let outside = root.appendingPathComponent("outside.json")
        try FileManager.default.moveItem(at: manifestURL, to: outside)
        try FileManager.default.createSymbolicLink(at: manifestURL, withDestinationURL: outside)
        do { _ = try await store.open(project.url); XCTFail() }
        catch { XCTAssertEqual(error as? ProjectError, .unsafePackage) }
    }
    func testDemoCaptureAndReconstruction() async throws {
        let service = DemoCaptureService()
        let compatibility = await service.compatibility()
        XCTAssertEqual(compatibility, .available)
        let record = try await service.capture()
        XCTAssertTrue(record.isDemo); XCTAssertEqual(record.imageCount, 48)
        let project = ScanProject(manifest: ScanManifest(name: "Demo", captureMethod: .demo), url: URL(fileURLWithPath: "/tmp/unused"))
        let result = try await DemoPhotogrammetryService().reconstruct(project)
        XCTAssertEqual(result.projectID, project.id); XCTAssertTrue(result.isDemo); XCTAssertNil(result.modelURL)
    }
    func testDemoCannotReconstructRealProject() async {
        let project = ScanProject(manifest: ScanManifest(name: "Real", captureMethod: .importedPhotos), url: URL(fileURLWithPath: "/tmp/unused"))
        do { _ = try await DemoPhotogrammetryService().reconstruct(project); XCTFail() } catch { }
    }
    func testReconstructionCancellation() async {
        let project = ScanProject(manifest: ScanManifest(name: "Demo", captureMethod: .demo), url: URL(fileURLWithPath: "/tmp/unused"))
        let task = Task { try await DemoPhotogrammetryService().reconstruct(project) }
        task.cancel()
        do { _ = try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
    }
    func testDemoCaptureCancellation() async {
        let task = Task { try await DemoCaptureService().capture() }
        task.cancel()
        do { _ = try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
    }
    func testProductionCaptureIsExplicitlyUnavailable() async {
        let service = UnavailableCaptureService()
        if case .available = await service.compatibility() { XCTFail() }
        do { _ = try await service.capture(); XCTFail() } catch { }
    }
}
