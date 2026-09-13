import Foundation
import Caliper3DCore

public enum IncomingCaptureError: Error, LocalizedError {
    case insufficientSpace, corruptMetadata, invalidState
    public var errorDescription: String? {
        switch self {
        case .insufficientSpace: "Not enough Mac storage to receive and finalize this capture. Free space and try again."
        case .corruptMetadata: "The received capture metadata does not match its file manifest."
        case .invalidState: "This transfer cannot continue from its current state. Reconnect and retry."
        }
    }
}
public actor IncomingCaptureStore {
    private struct Journal: Codable {
        let version: Int
        let resume: ResumeDescriptor
        let updatedAt: Date
    }
    private struct ActiveFile {
        let index: Int
        let handle: FileHandle
        var verifier: FileIntegrityVerifier
    }
    private let root: URL
    private let projects: LocalProjectStore
    private let availableBytes: @Sendable (URL) throws -> Int64
    private var manifest: TransferManifest?
    private var verified = Set<Int>()
    private var active: ActiveFile?
    private var finalizing = false
    public init(root: URL, projects: LocalProjectStore, availableBytes: @escaping @Sendable (URL) throws -> Int64 = { url in
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: url.path)
        return (attributes[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
    }) { self.root = root; self.projects = projects; self.availableBytes = availableBytes }
    deinit { try? active?.handle.close() }

    public func prepare(_ offer: TransferManifest) throws -> Set<Int> {
        guard active == nil, !finalizing else { throw IncomingCaptureError.invalidState }
        let bytes = try offer.canonicalData() // before creating any path
        try OwnedFileSystem.createDirectory(root)
        let folder = partial(offer.transferID)
        if FileManager.default.fileExists(atPath: folder.path) {
            try validateTree(folder)
            let old = try? JSONDecoder().decode(TransferManifest.self, from: readSmall(folder.appendingPathComponent("transfer-manifest.json"), maximum: TransferPolicy.maximumControlBytes))
            if (try? old?.digest()) != (try offer.digest()) {
                try FileManager.default.removeItem(at: folder)
            }
        }
        try OwnedFileSystem.createDirectory(folder)
        let dataset = folder.appendingPathComponent("dataset")
        for url in [dataset, dataset.appendingPathComponent("Images"), dataset.appendingPathComponent("Checkpoints")] { try OwnedFileSystem.createDirectory(url) }
        let pending = folder.appendingPathComponent("receiving.tmp")
        if FileManager.default.fileExists(atPath: pending.path) { try checkFile(pending); try FileManager.default.removeItem(at: pending) }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let journal = try? decoder.decode(Journal.self, from: readSmall(folder.appendingPathComponent("journal.json"), maximum: 256 * 1024))
        var candidates = Set<Int>()
        if let journal, journal.version == 1 { candidates = try journal.resume.candidates(for: offer) }
        var valid = Set<Int>()
        for index in candidates.sorted() {
            try Task.checkCancellation()
            do { try verifyFile(dataset.appendingPathComponent(offer.files[index].path), file: offer.files[index]); valid.insert(index) }
            catch is CancellationError { throw CancellationError() }
            catch { /* Corrupt/missing files must be resent, never trusted from journal alone. */ }
        }
        let remaining = offer.totalBytes - valid.reduce(0) { $0 + offer.files[$1].bytes }
        // Staged remaining bytes + one complete finalization copy + a small metadata reserve.
        let required = remaining + offer.totalBytes + 100 * 1024 * 1024
        guard try availableBytes(root) >= required else { throw IncomingCaptureError.insufficientSpace }
        manifest = offer; verified = valid
        try bytes.write(to: folder.appendingPathComponent("transfer-manifest.json"), options: .atomic)
        try saveJournal()
        return valid
    }
    public func begin(_ reference: FileReference) throws {
        guard let manifest, reference.transferID == manifest.transferID, manifest.files.indices.contains(reference.index),
              active == nil, !finalizing, !verified.contains(reference.index) else { throw IncomingCaptureError.invalidState }
        let pending = partial(manifest.transferID).appendingPathComponent("receiving.tmp")
        try OwnedFileSystem.validateAncestors(pending)
        guard !FileManager.default.fileExists(atPath: pending.path), FileManager.default.createFile(atPath: pending.path, contents: Data()) else { throw IncomingCaptureError.invalidState }
        active = ActiveFile(index: reference.index, handle: try FileHandle(forWritingTo: pending), verifier: try FileIntegrityVerifier(file: manifest.files[reference.index]))
    }
    public func append(_ bytes: Data) throws {
        guard var file = active, !finalizing else { throw IncomingCaptureError.invalidState }
        do {
            try file.verifier.consume(bytes); try file.handle.write(contentsOf: bytes); active = file
        } catch { try? file.handle.close(); active = nil; throw error }
    }
    public func complete(_ reference: FileReference) throws {
        guard let manifest, var file = active, reference.transferID == manifest.transferID, reference.index == file.index, !finalizing else { throw IncomingCaptureError.invalidState }
        defer { try? file.handle.close(); active = nil }
        try file.verifier.finish(); try file.handle.synchronize(); try file.handle.close()
        let folder = partial(manifest.transferID)
        let destination = folder.appendingPathComponent("dataset").appendingPathComponent(manifest.files[file.index].path)
        try OwnedFileSystem.createDirectory(destination.deletingLastPathComponent())
        if FileManager.default.fileExists(atPath: destination.path) { try checkFile(destination); try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: folder.appendingPathComponent("receiving.tmp"), to: destination)
        verified.insert(file.index); try saveJournal()
        AppLog.transfer.info("Received file verified and journaled")
    }
    public func finish() async throws -> ReceivedProjectResult {
        guard let manifest, active == nil, !finalizing, verified.count == manifest.files.count else { throw IncomingCaptureError.invalidState }
        finalizing = true; defer { finalizing = false }
        let folder = partial(manifest.transferID)
        let dataset = folder.appendingPathComponent("dataset")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(CaptureRecord.self, from: readSmall(dataset.appendingPathComponent("capture.json"), maximum: 128 * 1024))
        try record.validateReal()
        guard record.status == .ready, record.id == manifest.captureID, record.name == manifest.name,
              record.imageCount == manifest.imageCount, let created = record.createdAt,
              ISO8601DateFormatter().string(from: created) == manifest.createdAt,
              let metadata = manifest.files.first(where: { $0.path == "capture.json" }),
              record.totalBytes == manifest.totalBytes - metadata.bytes,
              record.sourceDevice?.name ?? "Capture device not recorded" == manifest.source.name,
              record.sourceDevice?.operatingSystem ?? "Not recorded" == manifest.source.operatingSystem,
              record.sourceDevice?.objectCaptureSupported == manifest.source.objectCaptureSupported else { throw IncomingCaptureError.corruptMetadata }
        let result = try await projects.finalizeReceivedCapture(transferID: manifest.transferID, record: record,
            expectedFiles: manifest.files.map { CaptureSourceFile(path: $0.path, bytes: $0.bytes, sha256: $0.sha256) }, datasetDigest: manifest.digest())
        try validateTree(folder); try FileManager.default.removeItem(at: folder)
        self.manifest = nil; verified = []
        return result
    }
    public func cancel() throws {
        guard !finalizing else { return }
        try? active?.handle.close(); active = nil
        if let manifest {
            let pending = partial(manifest.transferID).appendingPathComponent("receiving.tmp")
            if FileManager.default.fileExists(atPath: pending.path) { try checkFile(pending); try FileManager.default.removeItem(at: pending) }
        }
        manifest = nil; verified = []
    }
    private func saveJournal() throws {
        guard let manifest else { throw IncomingCaptureError.invalidState }
        let journal = Journal(version: 1, resume: try ResumeDescriptor(manifest: manifest, verifiedIndices: verified), updatedAt: Date())
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let url = partial(manifest.transferID).appendingPathComponent("journal.json")
        try OwnedFileSystem.validateAncestors(url); try encoder.encode(journal).write(to: url, options: .atomic)
    }
    private func partial(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString + ".partial") }
    private func verifyFile(_ url: URL, file: TransferFile) throws {
        try checkFile(url)
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard size.map(Int64.init) == file.bytes else { throw WireError.integrityMismatch }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var verifier = try FileIntegrityVerifier(file: file)
        while let data = try handle.read(upToCount: TransferPolicy.chunkBytes), !data.isEmpty {
            try Task.checkCancellation(); try verifier.consume(data)
        }
        try verifier.finish()
    }
    private func readSmall(_ url: URL, maximum: Int) throws -> Data {
        try checkFile(url)
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? maximum + 1
        guard size <= maximum else { throw IncomingCaptureError.corruptMetadata }
        return try Data(contentsOf: url)
    }
    private func checkFile(_ url: URL) throws {
        try OwnedFileSystem.validateAncestors(url)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw CaptureStorageError.unsafePath }
    }
    private func validateTree(_ root: URL) throws {
        var count = 0
        func visit(_ directory: URL, depth: Int) throws {
            guard depth < 256 else { throw CaptureStorageError.unsafePath }
            try OwnedFileSystem.validateDirectory(directory)
            for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                count += 1; guard count <= TransferPolicy.maximumFiles * 3 else { throw CaptureStorageError.unsafePath }
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { throw CaptureStorageError.unsafePath }
                if values.isDirectory == true { try visit(url, depth: depth + 1) } else { try checkFile(url) }
            }
        }
        try visit(root, depth: 0)
    }
}
