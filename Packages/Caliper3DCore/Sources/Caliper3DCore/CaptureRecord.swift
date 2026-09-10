import Foundation

public enum CaptureStatus: String, Codable, Sendable { case capturing, ready, interrupted, failed }
/// Real datasets are resolved by UUID through CaptureRepository, never by serialized absolute paths.
public struct CaptureRecord: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var imageCount: Int
    public var isDemo: Bool
    public var schemaVersion: Int?
    public var createdAt: Date?
    public var modifiedAt: Date?
    public var totalBytes: Int64?
    public var status: CaptureStatus?
    public init(id: UUID = UUID(), name: String, imageCount: Int, isDemo: Bool) {
        self.id = id; self.name = name; self.imageCount = imageCount; self.isDemo = isDemo
        if !isDemo {
            schemaVersion = 1; createdAt = Date(); modifiedAt = createdAt
            totalBytes = 0; status = .capturing
        }
    }
    public func validateReal() throws {
        guard !isDemo, schemaVersion == 1, let createdAt, let modifiedAt,
              modifiedAt >= createdAt, status != nil, let totalBytes, totalBytes >= 0,
              imageCount >= 0, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.count <= 120 else { throw CaptureStorageError.invalidMetadata }
    }
}
public struct CaptureDirectories: Sendable {
    public let id: UUID
    public let images: URL
    public let checkpoints: URL
    public init(id: UUID, images: URL, checkpoints: URL) {
        self.id = id; self.images = images; self.checkpoints = checkpoints
    }
}
public struct CaptureLibrary: Sendable {
    public var completed: [CaptureRecord] = []
    public var incomplete: [CaptureRecord] = []
    public var unreadableCount = 0
    public init() {}
}
public protocol CaptureRepository: Sendable {
    func allocate(name: String) async throws -> CaptureDirectories
    func complete(_ id: UUID) async throws -> CaptureRecord
    func markIncomplete(_ id: UUID, failed: Bool) async throws
    func library() async throws -> CaptureLibrary
    func rename(_ id: UUID, name: String) async throws -> CaptureRecord
    func delete(_ id: UUID) async throws
}
public enum CaptureStorageError: Error, LocalizedError, Equatable {
    case invalidMetadata, unsafePath, insufficientSpace, noImages, invalidName, alreadyCompleted
    public var errorDescription: String? {
        switch self {
        case .invalidMetadata: "Capture metadata is damaged or uses an unsupported version. Its files have been preserved."
        case .unsafePath: "The capture folder is not a safe app-owned directory."
        case .insufficientSpace: "Not enough free storage to start a scan. Free some space and try again."
        case .noImages: "Object Capture finished without any saved photos. The incomplete capture has been preserved."
        case .invalidName: "Use a capture name between 1 and 120 characters."
        case .alreadyCompleted: "This capture is already saved and cannot be overwritten."
        }
    }
}
