import Foundation

public enum CaptureMethod: String, Codable, Sendable { case objectCapture, importedPhotos, demo }
public enum ReconstructionState: String, Codable, Sendable { case notStarted, queued, processing, complete, failed }
public enum LengthUnit: String, Codable, CaseIterable, Sendable { case millimeters, centimeters, meters }
public struct Dimensions: Codable, Equatable, Sendable {
    public var width: Double
    public var height: Double
    public var depth: Double
    public init(width: Double, height: Double, depth: Double) {
        self.width = width; self.height = height; self.depth = depth
    }
}
public struct MeshStatistics: Codable, Equatable, Sendable {
    public var vertices: Int
    public var triangles: Int
    public init(vertices: Int, triangles: Int) { self.vertices = vertices; self.triangles = triangles }
}
public struct SourceDevice: Codable, Equatable, Sendable {
    public var name: String
    public var operatingSystem: String
    public var hasLiDAR: Bool?
    public init(name: String, operatingSystem: String, hasLiDAR: Bool?) {
        self.name = name; self.operatingSystem = operatingSystem; self.hasLiDAR = hasLiDAR
    }
}
public struct ScanManifest: Codable, Equatable, Identifiable, Sendable {
    public static let currentSchemaVersion = 1
    public var schemaVersion = currentSchemaVersion
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var modifiedAt: Date
    public var sourceDevice: SourceDevice?
    public var captureMethod: CaptureMethod
    public var imageCount: Int
    public var reconstructionState: ReconstructionState
    public var units: LengthUnit
    public var dimensions: Dimensions?
    public var meshStatistics: MeshStatistics?
    public init(id: UUID = UUID(), name: String, captureMethod: CaptureMethod, imageCount: Int = 0,
                sourceDevice: SourceDevice? = nil) {
        self.id = id; self.name = name; self.captureMethod = captureMethod
        self.imageCount = imageCount; self.sourceDevice = sourceDevice
        createdAt = Date(); modifiedAt = createdAt
        reconstructionState = .notStarted; units = .millimeters
    }
    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else { throw ProjectError.unsupportedSchema(schemaVersion) }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, imageCount >= 0,
              modifiedAt >= createdAt else { throw ProjectError.invalidManifest }
        if let d = dimensions {
            guard [d.width, d.height, d.depth].allSatisfy({ $0.isFinite && $0 > 0 }) else {
                throw ProjectError.invalidManifest
            }
        }
        if let s = meshStatistics, s.vertices < 0 || s.triangles < 0 { throw ProjectError.invalidManifest }
    }
}
public enum ProjectError: Error, LocalizedError, Equatable {
    case unsupportedSchema(Int), invalidManifest, unsafePackage, tooManyImages, unsupportedImage
    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version): return "Project schema \(version) is unsupported. This version reads schema 1."
        case .invalidManifest: return "The project manifest contains invalid values."
        case .unsafePackage: return "This project is not a safe Caliper3D package."
        case .tooManyImages: return "Import between 1 and 500 photos at a time."
        case .unsupportedImage: return "Choose JPEG, HEIC or PNG photos smaller than 100 MB each."
        }
    }
}
public enum ManifestCodec {
    public static func encode(_ manifest: ScanManifest) throws -> Data {
        try manifest.validate()
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(manifest)
    }
    public static func decode(_ data: Data) throws -> ScanManifest {
        // Inspect version before decoding the payload, so future schemas fail clearly.
        struct Header: Decodable { var schemaVersion: Int }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let header = try decoder.decode(Header.self, from: data)
        guard header.schemaVersion == ScanManifest.currentSchemaVersion else {
            throw ProjectError.unsupportedSchema(header.schemaVersion)
        }
        let manifest = try decoder.decode(ScanManifest.self, from: data)
        try manifest.validate(); return manifest
    }
}
public struct ScanProject: Identifiable, Equatable, Sendable {
    public var manifest: ScanManifest
    public var url: URL
    public var id: UUID { manifest.id }
    public init(manifest: ScanManifest, url: URL) { self.manifest = manifest; self.url = url }
}
public struct CaptureRecord: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var imageCount: Int
    public var isDemo: Bool
    public init(id: UUID = UUID(), name: String, imageCount: Int, isDemo: Bool) {
        self.id = id; self.name = name; self.imageCount = imageCount; self.isDemo = isDemo
    }
}
