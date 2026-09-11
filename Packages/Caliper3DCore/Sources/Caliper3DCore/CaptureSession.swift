import Foundation
import Observation

public enum CameraPermission: Sendable { case notDetermined, allowed, denied, restricted }
public protocol CameraPermissionService: Sendable {
    func status() async -> CameraPermission
    func request() async -> CameraPermission
}
public enum ScanPhase: String, Equatable, Sendable { case initializing, ready, detecting, capturing, finishing, completed, failed }
public enum ScanFeedback: String, CaseIterable, Sendable {
    case tooClose, tooFar, movingTooFast, lowLight, tooDark, outOfView, notFlippable, overCapturing, notDetected
    public var message: String {
        switch self {
        case .tooClose: "Move a little farther away."
        case .tooFar: "Move closer to the object."
        case .movingTooFast: "Move more slowly."
        case .lowLight: "More even lighting will help."
        case .tooDark: "The scene is too dark. Add light."
        case .outOfView: "Keep the object in view."
        case .notFlippable: "Keep this object in its current position."
        case .overCapturing: "You have many photos of this area. Try another angle."
        case .notDetected: "Point the camera at the object."
        }
    }
}
public enum ScanTracking: Equatable, Sendable {
    case normal, unavailable, initializing, relocalizing, excessiveMotion, insufficientFeatures
    public var message: String? {
        switch self {
        case .normal: nil
        case .unavailable: "Camera tracking is unavailable."
        case .initializing: "Hold steady while tracking starts."
        case .relocalizing: "Return to a previously scanned view slowly."
        case .excessiveMotion: "Hold the iPhone steady."
        case .insufficientFeatures: "Keep the object and its surroundings clearly visible."
        }
    }
}
public struct ScanSnapshot: Equatable, Sendable {
    public var phase: ScanPhase = .initializing
    public var shots = 0
    public var feedback: Set<ScanFeedback> = []
    public var tracking: ScanTracking = .initializing
    public var passCompleted = false
    public var paused = false
    public var failureIsStorage = false
    public var failure: String?
    public init() {}
    public var guidance: String? {
        tracking.message ?? ScanFeedback.allCases.first(where: feedback.contains)?.message
    }
    public var canDetect: Bool { phase == .ready && !paused }
    public var canCapture: Bool { phase == .detecting && !paused && tracking == .normal }
    public var canFinish: Bool { phase == .capturing && shots > 0 && !paused }
    public var canAddPass: Bool { phase == .capturing && passCompleted && !paused }
    public var canPause: Bool { [.ready, .detecting, .capturing].contains(phase) }
}
/// UI-isolated lifecycle boundary; implementations may own Apple's MainActor-only session.
/// This is intentionally separate from the legacy one-shot demo CaptureService.
@MainActor public protocol CaptureSessionDriver: AnyObject {
    var updates: AsyncStream<ScanSnapshot> { get }
    func start(_ directories: CaptureDirectories)
    func detect() -> Bool
    func resetDetection() -> Bool
    func startCapturing()
    func finish()
    func cancel()
    func pause()
    func resume()
    func nextPass()
    func nextPassAfterFlip()
    func stopObserving()
}
@MainActor public protocol CaptureSessionFactory {
    var isSupported: Bool { get }
    func makeSession() -> any CaptureSessionDriver
}

@MainActor @Observable
public final class CaptureSessionModel {
    public enum Stage: Equatable {
        case idle, checking, unsupported, permissionDenied, permissionRestricted, live, saving, review
        case failed(String), storageFailure(String), cancelled
    }
    public private(set) var stage: Stage = .idle
    public private(set) var snapshot = ScanSnapshot()
    public private(set) var driver: (any CaptureSessionDriver)?
    public private(set) var record: CaptureRecord?
    public private(set) var message: String?
    public private(set) var flipPending = false
    private let factory: any CaptureSessionFactory
    private let permission: any CameraPermissionService
    private let repository: any CaptureRepository
    private var directories: CaptureDirectories?
    private var observation: Task<Void, Never>?
    private var generation = UUID()
    private var didComplete = false
    private var needsPause = false
    public init(factory: any CaptureSessionFactory, permission: any CameraPermissionService, repository: any CaptureRepository) {
        self.factory = factory; self.permission = permission; self.repository = repository
    }
    public func begin() async {
        guard stage == .idle else { return }
        let token = generation
        stage = .checking
        guard factory.isSupported else { stage = .unsupported; return }
        var access = await permission.status()
        guard token == generation else { return }
        if access == .notDetermined { access = await permission.request() }
        guard token == generation else { return }
        switch access {
        case .denied, .notDetermined: stage = .permissionDenied; return
        case .restricted: stage = .permissionRestricted; return
        case .allowed: break
        }
        do {
            let allocated = try await repository.allocate(name: "Scan " + Date().formatted(date: .abbreviated, time: .shortened))
            guard token == generation else {
                try await repository.markIncomplete(allocated.id, failed: false); return
            }
            directories = allocated
            let session = factory.makeSession()
            driver = session; stage = .live
            observation = Task { [weak self, updates = session.updates] in
                for await value in updates {
                    guard !Task.isCancelled, let self, token == self.generation else { return }
                    await self.receive(value)
                }
            }
            session.start(allocated)
        } catch { if token == generation { stage = .storageFailure(error.localizedDescription) } }
    }
    private func receive(_ value: ScanSnapshot) async {
        snapshot = value
        if needsPause, value.canPause, !value.paused { driver?.pause() }
        if value.phase == .completed, !didComplete, let directories {
            didComplete = true
            stage = .saving
            await save(directories.id)
        } else if value.phase == .failed, !didComplete {
            let failure = value.failure ?? "Object Capture could not continue."
            stage = value.failureIsStorage ? .storageFailure(failure) : .failed(failure)
            driver?.stopObserving()
            if let directories {
                do { try await repository.markIncomplete(directories.id, failed: true) }
                catch { stage = .storageFailure("Capture failed, and its metadata could not be updated: " + error.localizedDescription) }
            }
        }
    }
    private func save(_ id: UUID) async {
        do { record = try await repository.complete(id); stage = .review }
        catch { stage = .storageFailure(error.localizedDescription) }
        driver?.stopObserving()
    }
    public func retrySave() async {
        guard didComplete, let directories, case .storageFailure = stage else { return }
        stage = .saving; await save(directories.id)
    }
    public var canRetrySave: Bool { didComplete }
    public func detect() {
        guard stage == .live, snapshot.canDetect else { return }
        message = driver?.detect() == true ? nil : "Object detection could not start. Keep the object in view and try again."
    }
    public func resetDetection() {
        guard stage == .live, snapshot.phase == .detecting, !snapshot.paused else { return }
        message = driver?.resetDetection() == true ? nil : "The selection could not be reset. Try again."
    }
    public func capture() {
        guard stage == .live, snapshot.canCapture else { return }
        message = nil; driver?.startCapturing()
    }
    public func finish() {
        guard stage == .live, snapshot.canFinish else { return }
        message = nil; driver?.finish()
        // Remain live until Apple's finishing/completed state, never fabricate completion.
    }
    public func nextPass() {
        guard stage == .live, snapshot.canAddPass else { return }
        driver?.nextPass()
    }
    public func prepareFlip() {
        guard stage == .live, snapshot.canAddPass, !snapshot.feedback.contains(.notFlippable) else { return }
        flipPending = true; driver?.pause()
    }
    public func confirmFlip() {
        guard flipPending, stage == .live, snapshot.phase == .capturing else { return }
        flipPending = false; needsPause = false; driver?.nextPassAfterFlip(); driver?.resume()
    }
    public func cancelFlip() { flipPending = false; resume() }
    public func pause() {
        needsPause = true
        guard stage == .live, snapshot.canPause else { return }
        driver?.pause()
    }
    public func resume() {
        guard stage == .live, snapshot.canPause, !flipPending else { return }
        needsPause = false; driver?.resume()
    }
    public func cancel() async {
        guard stage != .saving, stage != .cancelled else { return } // completion metadata must settle before dismissal
        generation = UUID(); observation?.cancel(); observation = nil
        if !didComplete { driver?.cancel() }
        driver?.stopObserving(); driver = nil
        if let directories, !didComplete {
            do { try await repository.markIncomplete(directories.id, failed: false) }
            catch { stage = .storageFailure(error.localizedDescription); return }
        }
        stage = .cancelled
    }
    public func releaseCompletedSession() {
        guard stage == .review else { return }
        observation?.cancel(); observation = nil; driver?.stopObserving(); driver = nil
    }
}
