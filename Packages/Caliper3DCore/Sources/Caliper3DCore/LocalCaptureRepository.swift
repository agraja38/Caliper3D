import Foundation
import ImageIO

/// App-private, UUID-only storage. No operations follow symlinks within a capture tree.
public actor LocalCaptureRepository: CaptureRepository {
    private let root: URL
    private let files = FileManager.default
    private let availableBytes: @Sendable (URL) throws -> Int64
    /// A small startup reserve, not a promise that a complete scan will fit.
    public static let startupReserve: Int64 = 100 * 1024 * 1024
    public init(root: URL, availableBytes: @escaping @Sendable (URL) throws -> Int64 = { url in
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: url.path)
        return (attributes[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
    }) {
        self.root = root; self.availableBytes = availableBytes
    }
    public func allocate(name: String) throws -> CaptureDirectories {
        let name = try validatedName(name)
        try prepareRoot()
        guard try availableBytes(root) >= Self.startupReserve else { throw CaptureStorageError.insufficientSpace }
        let id = UUID(), folder = root.appendingPathComponent(UUID().uuidString) // staging independent of record ID
        try files.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: folder) }
        for child in ["Images", "Checkpoints"] {
            try files.createDirectory(at: folder.appendingPathComponent(child), withIntermediateDirectories: false)
        }
        let record = CaptureRecord(id: id, name: name, imageCount: 0, isDemo: false)
        try encode(record).write(to: folder.appendingPathComponent("capture.json"), options: .atomic)
        let destination = root.appendingPathComponent(id.uuidString)
        try files.moveItem(at: folder, to: destination)
        return CaptureDirectories(id: id, images: destination.appendingPathComponent("Images"),
                                  checkpoints: destination.appendingPathComponent("Checkpoints"))
    }
    public func complete(_ id: UUID) throws -> CaptureRecord {
        var record = try read(id)
        guard record.status != .ready else { throw CaptureStorageError.alreadyCompleted }
        let stats = try inspect(owned(id))
        guard stats.images > 0 else { throw CaptureStorageError.noImages }
        record.imageCount = stats.images; record.totalBytes = stats.bytes
        record.status = .ready; record.modifiedAt = Date()
        try write(record); return record
    }
    public func markIncomplete(_ id: UUID, failed: Bool) throws {
        var record = try read(id)
        guard record.status != .ready else { return }
        record.status = failed ? .failed : .interrupted
        record.modifiedAt = Date()
        // Metadata only: RealityKit may still be settling its writes after cancellation.
        try write(record)
    }
    public func library() throws -> CaptureLibrary {
        try prepareRoot()
        var result = CaptureLibrary()
        for url in try files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            guard let id = UUID(uuidString: url.lastPathComponent), url.lastPathComponent == id.uuidString else {
                result.unreadableCount += 1; continue
            }
            do {
                let record = try read(id)
                if record.status == .ready {
                    let stats = try inspect(owned(id))
                    guard stats.images > 0, stats.images == record.imageCount, stats.bytes == record.totalBytes else {
                        throw CaptureStorageError.invalidMetadata
                    }
                    result.completed.append(record)
                }
                else { result.incomplete.append(record) }
            } catch { result.unreadableCount += 1 }
        }
        result.completed.sort { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
        result.incomplete.sort { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
        return result
    }
    public func rename(_ id: UUID, name: String) throws -> CaptureRecord {
        var record = try read(id)
        record.name = try validatedName(name); record.modifiedAt = Date()
        try write(record); return record
    }
    public func delete(_ id: UUID) throws {
        let folder = try owned(id)
        _ = try read(id)
        _ = try inspect(folder) // reject links anywhere, including checkpoint trees
        try files.removeItem(at: folder)
    }
    public func previewJPEG(_ id: UUID) throws -> Data? {
        guard try read(id).status == .ready else { return nil }
        let folder = try owned(id)
        _ = try inspect(folder)
        let images = folder.appendingPathComponent("Images")
        let candidates = try files.contentsOfDirectory(at: images, includingPropertiesForKeys: nil)
            .filter { ["heic", "heif", "jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for url in candidates.prefix(3) {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= 100_000_000 else { continue }
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 640
                  ] as CFDictionary) else { continue }
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, thumbnail, nil)
            guard CGImageDestinationFinalize(destination) else { return nil }
            return data as Data
        }
        return nil
    }
    private func validatedName(_ value: String) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 120, !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw CaptureStorageError.invalidName
        }
        return name
    }
    private func prepareRoot() throws {
        try rejectSymbolicAncestors(root)
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        try validateDirectory(root)
    }
    private func validateDirectory(_ url: URL) throws {
        try rejectSymbolicAncestors(url)
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw CaptureStorageError.unsafePath }
    }
    private func rejectSymbolicAncestors(_ url: URL) throws {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.pathComponents.contains("..") else {
            throw CaptureStorageError.unsafePath
        }
        // Foundation preserves Darwin's /var and /tmp aliases even after resolving symlinks.
        // Permit only those exact system aliases with their expected targets; no app-owned link.
        // Inspect ancestors even when the final leaf does not exist yet.
        var components = url.path.split(separator: "/").map(String.init)
        while !components.isEmpty {
            let path = "/" + components.joined(separator: "/")
            if let attributes = try? files.attributesOfItem(atPath: path),
               attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                let destination = try files.destinationOfSymbolicLink(atPath: path)
                let expectedSystemTarget = ["/var": "private/var", "/tmp": "private/tmp"][path]
                guard let expectedSystemTarget,
                      destination == expectedSystemTarget || destination == "/" + expectedSystemTarget else {
                    throw CaptureStorageError.unsafePath
                }
            }
            components.removeLast()
        }
    }
    private func owned(_ id: UUID) throws -> URL {
        try validateDirectory(root)
        let folder = root.appendingPathComponent(id.uuidString)
        try validateDirectory(folder)
        return folder
    }
    private func read(_ id: UUID) throws -> CaptureRecord {
        let folder = try owned(id)
        try validateDirectory(folder.appendingPathComponent("Images"))
        try validateDirectory(folder.appendingPathComponent("Checkpoints"))
        let url = folder.appendingPathComponent("capture.json")
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= 128 * 1024 else { throw CaptureStorageError.unsafePath }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(CaptureRecord.self, from: Data(contentsOf: url))
        try record.validateReal()
        guard record.id == id else { throw CaptureStorageError.invalidMetadata }
        return record
    }
    private func encode(_ record: CaptureRecord) throws -> Data {
        try record.validateReal()
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(record)
    }
    private func write(_ record: CaptureRecord) throws {
        _ = try read(record.id) // validate existing ownership and metadata before replacement
        try encode(record).write(to: owned(record.id).appendingPathComponent("capture.json"), options: .atomic)
    }
    private func inspect(_ folder: URL) throws -> (images: Int, bytes: Int64) {
        var imageCount = 0, bytes: Int64 = 0
        func visit(_ directory: URL, isRoot: Bool = false, isImages: Bool = false) throws {
            for url in try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey])
                guard values.isSymbolicLink != true else { throw CaptureStorageError.unsafePath }
                if values.isDirectory == true { try visit(url, isImages: isRoot && url.lastPathComponent == "Images") }
                else if values.isRegularFile == true {
                    // Dataset size excludes capture.json so metadata edits do not change the recorded size.
                    if !(isRoot && url.lastPathComponent == "capture.json") { bytes += Int64(values.fileSize ?? 0) }
                    if isImages,
                       ["heic", "heif", "jpg", "jpeg", "png"].contains(url.pathExtension.lowercased()),
                       (values.fileSize ?? 0) > 0 { imageCount += 1 }
                } else { throw CaptureStorageError.unsafePath }
            }
        }
        try visit(folder, isRoot: true); return (imageCount, bytes)
    }
}
