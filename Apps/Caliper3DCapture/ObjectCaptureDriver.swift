import SwiftUI
import Observation
import RealityKit
import Caliper3DCore

@MainActor
struct ObjectCaptureFactory: CaptureSessionFactory {
    var isSupported: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        ObjectCaptureSession.isSupported
        #endif
    }
    func makeSession() -> any CaptureSessionDriver {
        // The model checks support and permission before calling the factory.
        precondition(isSupported, "Object Capture must be supported before constructing a session")
        return ObjectCaptureDriver()
    }
}

@MainActor
final class ObjectCaptureDriver: CaptureSessionDriver {
    let session = ObjectCaptureSession()
    let updates: AsyncStream<ScanSnapshot>
    private let continuation: AsyncStream<ScanSnapshot>.Continuation
    private var isObserving = false
    private var observers: [Task<Void, Never>] = []
    init() {
        let stream = AsyncStream<ScanSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        updates = stream.stream; continuation = stream.continuation
    }
    func start(_ directories: CaptureDirectories) {
        var configuration = ObjectCaptureSession.Configuration()
        configuration.isOverCaptureEnabled = true
        configuration.checkpointDirectory = directories.checkpoints
        observe()
        session.start(imagesDirectory: directories.images, configuration: configuration)
        publish()
    }
    // Recheck Apple's current state to reject commands from a UI snapshot that is a frame behind.
    func detect() -> Bool {
        guard session.state == .ready, !session.isPaused else { return false }
        return session.startDetecting()
    }
    func resetDetection() -> Bool {
        guard session.state == .detecting, !session.isPaused else { return false }
        return session.resetDetection()
    }
    func startCapturing() {
        guard session.state == .detecting, !session.isPaused, session.cameraTracking == .normal else { return }
        session.startCapturing()
    }
    func finish() {
        guard session.state == .capturing, !session.isPaused, session.numberOfShotsTaken > 0 else { return }
        session.finish()
    }
    func cancel() {
        switch session.state {
        case .completed, .failed: return
        default: session.cancel()
        }
    }
    func pause() {
        guard [.ready, .detecting, .capturing].contains(session.state), !session.isPaused else { return }
        session.pause()
    }
    func resume() {
        guard [.ready, .detecting, .capturing].contains(session.state), session.isPaused else { return }
        session.resume()
    }
    func nextPass() {
        guard session.state == .capturing, session.userCompletedScanPass, !session.isPaused else { return }
        session.beginNewScanPass()
    }
    func nextPassAfterFlip() {
        guard session.state == .capturing, session.userCompletedScanPass,
              !session.feedback.contains(.objectNotFlippable) else { return }
        session.beginNewScanPassAfterFlip()
    }
    func stopObserving() {
        isObserving = false
        observers.forEach { $0.cancel() }; observers.removeAll(); continuation.finish()
    }
    deinit { observers.forEach { $0.cancel() }; continuation.finish() }
    private func observe() {
        isObserving = true
        observeTracking()
        observers = [
            Task { [weak self, session] in
                for await _ in session.stateUpdates { guard !Task.isCancelled else { break }; self?.publish() }
            },
            Task { [weak self, session] in
                for await _ in session.feedbackUpdates { guard !Task.isCancelled else { break }; self?.publish() }
            },
            Task { [weak self, session] in
                for await _ in session.numberOfShotsTakenUpdates { guard !Task.isCancelled else { break }; self?.publish() }
            },
            Task { [weak self, session] in
                for await _ in session.userCompletedScanPassUpdates { guard !Task.isCancelled else { break }; self?.publish() }
            },
            Task { [weak self, session] in
                for await _ in session.isPausedUpdates { guard !Task.isCancelled else { break }; self?.publish() }
            }
        ]
    }
    private func observeTracking() {
        guard isObserving else { return }
        // The installed SDK's Tracking does not conform to Sendable, although Updates<Element>
        // requires it. Observe the MainActor property directly instead of moving it across an await.
        withObservationTracking {
            _ = session.cameraTracking
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeTracking() }
        }
        publish()
    }
    private func publish() {
        var snapshot = ScanSnapshot()
        switch session.state {
        case .initializing: snapshot.phase = .initializing
        case .ready: snapshot.phase = .ready
        case .detecting: snapshot.phase = .detecting
        case .capturing: snapshot.phase = .capturing
        case .finishing: snapshot.phase = .finishing
        case .completed: snapshot.phase = .completed
        case .failed(let error):
            snapshot.phase = .failed
            if let captureError = error as? ObjectCaptureSession.Error {
                snapshot.failure = captureError.localizedDescription
                switch captureError {
                case .directoryNotEmpty, .insufficientStorage: snapshot.failureIsStorage = true
                default: break
                }
            } else { snapshot.failure = error.localizedDescription }
        @unknown default:
            snapshot.phase = .failed; snapshot.failure = "This Object Capture state is not supported by this app."
        }
        snapshot.shots = session.numberOfShotsTaken
        snapshot.passCompleted = session.userCompletedScanPass
        snapshot.paused = session.isPaused
        snapshot.feedback = Set(session.feedback.compactMap(Self.feedback))
        switch session.cameraTracking {
        case .normal: snapshot.tracking = .normal
        case .notAvailable: snapshot.tracking = .unavailable
        case .limited(let reason):
            switch reason {
            case .initializing: snapshot.tracking = .initializing
            case .relocalizing: snapshot.tracking = .relocalizing
            case .excessiveMotion: snapshot.tracking = .excessiveMotion
            case .insufficientFeatures: snapshot.tracking = .insufficientFeatures
            @unknown default: snapshot.tracking = .unavailable
            }
        @unknown default: snapshot.tracking = .unavailable
        }
        continuation.yield(snapshot)
    }
    private static func feedback(_ value: ObjectCaptureSession.Feedback) -> ScanFeedback? {
        if #available(iOS 17.4, *), value == .objectNotDetected { return .notDetected }
        switch value {
        case .objectTooClose: return .tooClose
        case .objectTooFar: return .tooFar
        case .movingTooFast: return .movingTooFast
        case .environmentLowLight: return .lowLight
        case .environmentTooDark: return .tooDark
        case .outOfFieldOfView: return .outOfView
        case .objectNotFlippable: return .notFlippable
        case .overCapturing: return .overCapturing
        default: return nil // New OS feedback remains visible in Apple's capture overlay.
        }
    }
}
