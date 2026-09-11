import Foundation
import OSLog

public protocol ScanProjectStore: Sendable {
    func list() async throws -> [ScanProject]
    func create(_ manifest: ScanManifest) async throws -> ScanProject
    func open(_ url: URL) async throws -> ScanProject
    func importPhotos(_ urls: [URL], name: String) async throws -> ScanProject
}
public enum CaptureCompatibility: Equatable, Sendable {
    case available, unavailable(String)
}
/// Legacy one-shot boundary for temporary demo capture only. Production uses CaptureSessionDriver.
public protocol CaptureService: Sendable {
    func compatibility() async -> CaptureCompatibility
    func capture() async throws -> CaptureRecord
}
public protocol PhotogrammetryService: Sendable {
    func reconstruct(_ project: ScanProject) async throws -> ReconstructionResult
}
public struct ReconstructionResult: Sendable, Equatable {
    public let projectID: UUID
    public let isDemo: Bool
    public let modelURL: URL?
    public init(projectID: UUID, isDemo: Bool, modelURL: URL?) {
        self.projectID = projectID; self.isDemo = isDemo; self.modelURL = modelURL
    }
}
public enum ServiceError: Error, LocalizedError {
    case notImplemented(String)
    public var errorDescription: String? {
        switch self { case .notImplemented(let name): return "\(name) is not available in this foundation release." }
    }
}
public struct UnavailableCaptureService: CaptureService {
    public init() {}
    public func compatibility() async -> CaptureCompatibility {
        .unavailable("Live Object Capture is coming next. Use demo mode to explore the workflow.")
    }
    public func capture() async throws -> CaptureRecord { throw ServiceError.notImplemented("Live capture") }
}
public struct DemoCaptureService: CaptureService {
    public init() {}
    public func compatibility() async -> CaptureCompatibility { .available }
    public func capture() async throws -> CaptureRecord {
        try await Task.sleep(for: .milliseconds(800))
        return CaptureRecord(name: "Demo Object", imageCount: 48, isDemo: true)
    }
}
public struct DemoPhotogrammetryService: PhotogrammetryService {
    public init() {}
    public func reconstruct(_ project: ScanProject) async throws -> ReconstructionResult {
        guard project.manifest.captureMethod == .demo else { throw ServiceError.notImplemented("Real reconstruction") }
        try await Task.sleep(for: .seconds(2))
        return ReconstructionResult(projectID: project.id, isDemo: true, modelURL: nil)
    }
}
public enum AppLog {
    public static let app = Logger(subsystem: "org.caliper3d", category: "app")
    public static let capture = Logger(subsystem: "org.caliper3d", category: "capture")
    public static let network = Logger(subsystem: "org.caliper3d", category: "network")
    public static let transfer = Logger(subsystem: "org.caliper3d", category: "transfer")
    public static let reconstruction = Logger(subsystem: "org.caliper3d", category: "reconstruction")
    public static let mesh = Logger(subsystem: "org.caliper3d", category: "mesh")
    public static let export = Logger(subsystem: "org.caliper3d", category: "export")
    public static let installer = Logger(subsystem: "org.caliper3d", category: "installer")
    public static let filesystem = Logger(subsystem: "org.caliper3d", category: "filesystem")
}
