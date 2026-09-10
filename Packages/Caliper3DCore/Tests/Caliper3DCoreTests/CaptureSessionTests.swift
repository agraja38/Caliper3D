import XCTest
@testable import Caliper3DCore

private actor PermissionStub: CameraPermissionService {
    var value: CameraPermission
    let response: CameraPermission
    private(set) var requests = 0
    init(_ value: CameraPermission, response: CameraPermission = .allowed) { self.value = value; self.response = response }
    func status() -> CameraPermission { value }
    func request() -> CameraPermission { requests += 1; value = response; return response }
}
private actor RepositoryStub: CaptureRepository {
    let id = UUID()
    var completes = 0
    var allocations = 0
    var interrupted = 0
    var failSave = false
    var failAllocation = false
    func setFailSave(_ value: Bool) { failSave = value }
    func setFailAllocation() { failAllocation = true }
    func allocate(name: String) throws -> CaptureDirectories {
        allocations += 1
        if failAllocation { throw CaptureStorageError.insufficientSpace }
        return CaptureDirectories(id: id, images: URL(fileURLWithPath: "/unused/Images"), checkpoints: URL(fileURLWithPath: "/unused/Checkpoints"))
    }
    func complete(_ id: UUID) throws -> CaptureRecord {
        completes += 1
        if failSave { throw CaptureStorageError.noImages }
        var record = CaptureRecord(id: id, name: "Real", imageCount: 3, isDemo: false)
        record.status = .ready; return record
    }
    func markIncomplete(_ id: UUID, failed: Bool) { interrupted += 1 }
    func library() -> CaptureLibrary { CaptureLibrary() }
    func rename(_ id: UUID, name: String) throws -> CaptureRecord { throw CaptureStorageError.invalidMetadata }
    func delete(_ id: UUID) {}
}
@MainActor private final class DriverStub: CaptureSessionDriver {
    let updates: AsyncStream<ScanSnapshot>
    let continuation: AsyncStream<ScanSnapshot>.Continuation
    var actions: [String] = []
    init() { let stream = AsyncStream<ScanSnapshot>.makeStream(); updates = stream.stream; continuation = stream.continuation }
    func emit(_ phase: ScanPhase, shots: Int = 0, pass: Bool = false, paused: Bool = false) {
        var value = ScanSnapshot(); value.phase = phase; value.shots = shots; value.passCompleted = pass
        value.paused = paused; value.tracking = .normal; continuation.yield(value)
    }
    func start(_ directories: CaptureDirectories) { actions.append("start") }
    func detect() -> Bool { actions.append("detect"); return true }
    func resetDetection() -> Bool { actions.append("reset"); return true }
    func startCapturing() { actions.append("capture") }
    func finish() { actions.append("finish") }
    func cancel() { actions.append("cancel") }
    func pause() { actions.append("pause") }
    func resume() { actions.append("resume") }
    func nextPass() { actions.append("pass") }
    func nextPassAfterFlip() { actions.append("flip") }
    func stopObserving() { continuation.finish() }
}
@MainActor private final class FactoryStub: CaptureSessionFactory {
    var isSupported: Bool
    var made = 0
    let driver = DriverStub()
    init(supported: Bool = true) { isSupported = supported }
    func makeSession() -> any CaptureSessionDriver { made += 1; return driver }
}
@MainActor final class CaptureSessionTests: XCTestCase {
    private func settle(_ predicate: () -> Bool) async {
        for _ in 0..<200 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("State did not settle")
    }
    func testUnsupportedNeverRequestsPermissionOrConstructsSession() async {
        let factory = FactoryStub(supported: false), permission = PermissionStub(.notDetermined), repo = RepositoryStub()
        let model = CaptureSessionModel(factory: factory, permission: permission, repository: repo)
        await model.begin()
        XCTAssertEqual(model.stage, .unsupported); XCTAssertEqual(factory.made, 0)
        let requests = await permission.requests, allocations = await repo.allocations
        XCTAssertEqual(requests, 0); XCTAssertEqual(allocations, 0)
    }
    func testDeniedAndRestrictedNeverAllocateOrConstruct() async {
        for permission in [CameraPermission.denied, .restricted] {
            let factory = FactoryStub(), authorization = PermissionStub(permission), repo = RepositoryStub()
            let model = CaptureSessionModel(factory: factory, permission: authorization, repository: repo)
            await model.begin()
            XCTAssertEqual(model.stage, permission == .denied ? .permissionDenied : .permissionRestricted)
            XCTAssertEqual(factory.made, 0)
            let requests = await authorization.requests, allocations = await repo.allocations
            XCTAssertEqual(requests, 0); XCTAssertEqual(allocations, 0)
        }
    }
    func testPermissionRequestedOnceOnlyWhenStarting() async {
        let permission = PermissionStub(.notDetermined), factory = FactoryStub(), repo = RepositoryStub()
        let model = CaptureSessionModel(factory: factory, permission: permission, repository: repo)
        let before = await permission.requests; XCTAssertEqual(before, 0)
        await model.begin(); await model.begin()
        let after = await permission.requests; XCTAssertEqual(after, 1); XCTAssertEqual(factory.made, 1)
        await model.cancel()
    }
    func testDeniedRequestDoesNotCreateSession() async {
        let factory = FactoryStub(), permission = PermissionStub(.notDetermined, response: .denied)
        let model = CaptureSessionModel(factory: factory, permission: permission, repository: RepositoryStub())
        await model.begin(); XCTAssertEqual(model.stage, .permissionDenied); XCTAssertEqual(factory.made, 0)
    }
    func testStorageFailureIsNotCameraFailure() async {
        let repo = RepositoryStub(), factory = FactoryStub(); await repo.setFailAllocation()
        let model = CaptureSessionModel(factory: factory, permission: PermissionStub(.allowed), repository: repo)
        await model.begin()
        guard case .storageFailure = model.stage else { return XCTFail() }
        XCTAssertEqual(factory.made, 0)
    }
    func testActualCompletionRequiredBeforeSaving() async {
        let factory = FactoryStub(), repo = RepositoryStub()
        let model = CaptureSessionModel(factory: factory, permission: PermissionStub(.allowed), repository: repo)
        await model.begin()
        model.capture(); model.finish(); XCTAssertEqual(factory.driver.actions, ["start"])
        factory.driver.emit(.ready); await settle { model.snapshot.phase == .ready }; model.detect()
        factory.driver.emit(.detecting); await settle { model.snapshot.phase == .detecting }; model.capture()
        factory.driver.emit(.capturing, shots: 3); await settle { model.snapshot.phase == .capturing }; model.finish()
        XCTAssertEqual(model.stage, .live)
        var count = await repo.completes; XCTAssertEqual(count, 0)
        factory.driver.emit(.finishing, shots: 3); await settle { model.snapshot.phase == .finishing }
        count = await repo.completes; XCTAssertEqual(count, 0)
        factory.driver.emit(.completed, shots: 3); await settle { model.stage == .review }
        count = await repo.completes; XCTAssertEqual(count, 1); XCTAssertEqual(model.record?.imageCount, 3)
        model.releaseCompletedSession()
    }
    func testFailurePreservesIncompleteAndNeverSaves() async {
        let factory = FactoryStub(), repo = RepositoryStub()
        let model = CaptureSessionModel(factory: factory, permission: PermissionStub(.allowed), repository: repo)
        await model.begin(); factory.driver.emit(.failed)
        await settle { if case .failed = model.stage { return true }; return false }
        let count = await repo.completes; XCTAssertEqual(count, 0)
        await model.cancel()
    }
    func testCancellationIgnoresLateCompletion() async {
        let factory = FactoryStub(), repo = RepositoryStub()
        let model = CaptureSessionModel(factory: factory, permission: PermissionStub(.allowed), repository: repo)
        await model.begin(); await model.cancel(); factory.driver.emit(.completed, shots: 10)
        XCTAssertEqual(model.stage, .cancelled)
        let count = await repo.completes, interrupted = await repo.interrupted
        XCTAssertEqual(count, 0); XCTAssertEqual(interrupted, 1)
    }
    func testSaveFailureCanRetryWithoutRecapturing() async {
        let factory = FactoryStub(), repo = RepositoryStub(); await repo.setFailSave(true)
        let model = CaptureSessionModel(factory: factory, permission: PermissionStub(.allowed), repository: repo)
        await model.begin(); factory.driver.emit(.completed, shots: 3)
        await settle { if case .storageFailure = model.stage { return true }; return false }
        XCTAssertTrue(model.canRetrySave); XCTAssertNil(model.record)
        await repo.setFailSave(false); await model.retrySave()
        XCTAssertEqual(model.stage, .review); XCTAssertEqual(factory.made, 1)
        model.releaseCompletedSession()
    }
    func testPassAndFlipAreOnlyOfferedAfterActualPassCompletion() async {
        let factory = FactoryStub()
        let model = CaptureSessionModel(factory: factory, permission: PermissionStub(.allowed), repository: RepositoryStub())
        await model.begin(); factory.driver.emit(.capturing, shots: 5)
        await settle { model.snapshot.shots == 5 }
        model.nextPass(); model.prepareFlip(); XCTAssertFalse(model.flipPending)
        factory.driver.emit(.capturing, shots: 5, pass: true); await settle { model.snapshot.passCompleted }
        model.nextPass(); model.prepareFlip(); XCTAssertTrue(model.flipPending)
        XCTAssertEqual(factory.driver.actions.suffix(2), ["pass", "pause"])
        model.confirmFlip(); XCTAssertFalse(model.flipPending)
        XCTAssertEqual(factory.driver.actions.suffix(2), ["flip", "resume"])
        await model.cancel()
    }
    func testFeedbackAndTrackingMapping() {
        XCTAssertEqual(ScanFeedback.movingTooFast.message, "Move more slowly.")
        XCTAssertEqual(ScanFeedback.tooDark.message, "The scene is too dark. Add light.")
        XCTAssertEqual(ScanTracking.relocalizing.message, "Return to a previously scanned view slowly.")
        XCTAssertNil(ScanTracking.normal.message)
        for feedback in ScanFeedback.allCases { XCTAssertFalse(feedback.message.isEmpty) }
        var value = ScanSnapshot(); value.tracking = .normal; value.feedback = [.tooFar]
        XCTAssertEqual(value.guidance, ScanFeedback.tooFar.message)
        value.tracking = .excessiveMotion
        XCTAssertEqual(value.guidance, ScanTracking.excessiveMotion.message)
    }
}
