import Foundation
import Caliper3DCore

public struct PreparedCaptureTransfer: Sendable {
    public let manifest: TransferManifest
    public let source: any CaptureDataSource
    public static func prepare(captureID: UUID, repository: any CaptureRepository) async throws -> Self {
        let source = try await repository.prepareSource(captureID)
        let description = try await source.describe()
        let record = description.record
        guard let created = record.createdAt, record.status == .ready, !record.isDemo else { throw WireError.invalidManifest }
        let files = description.files.map { TransferFile(path: $0.path, bytes: $0.bytes, sha256: $0.sha256) }
        var total: Int64 = 0
        for file in files {
            guard file.bytes <= TransferPolicy.maximumTotalBytes - total else { throw WireError.invalidManifest }; total += file.bytes
        }
        let device = record.sourceDevice
        let manifest = TransferManifest(transferID: captureID, captureID: captureID, name: record.name,
            createdAt: ISO8601DateFormatter().string(from: created), source: TransferSource(
                name: device?.name ?? "Capture device not recorded", operatingSystem: device?.operatingSystem ?? "Not recorded",
                objectCaptureSupported: device?.objectCaptureSupported), imageCount: record.imageCount, totalBytes: total, files: files)
        _ = try manifest.canonicalData()
        return Self(manifest: manifest, source: source)
    }
}
