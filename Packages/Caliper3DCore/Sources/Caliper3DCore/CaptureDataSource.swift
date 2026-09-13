import Foundation
import CryptoKit

public struct CaptureSourceDevice: Codable, Equatable, Sendable {
    public let name: String
    public let operatingSystem: String
    public let objectCaptureSupported: Bool
    public init(name: String, operatingSystem: String, objectCaptureSupported: Bool) {
        self.name = name; self.operatingSystem = operatingSystem; self.objectCaptureSupported = objectCaptureSupported
    }
}
public enum CaptureSourceLimits {
    public static let chunkBytes = 256 * 1024
    public static let maximumFiles = 10_000
    public static let maximumFileBytes: Int64 = 16 * 1024 * 1024 * 1024
    public static let maximumTotalBytes: Int64 = 128 * 1024 * 1024 * 1024
}
public struct CaptureSourceFile: Sendable {
    public let path: String
    public let bytes: Int64
    public let sha256: String
}
public struct CaptureSourceDescription: Sendable {
    public let record: CaptureRecord
    public let files: [CaptureSourceFile]
}
/// A read-only capability issued by CaptureRepository. Callers address validated file indices,
/// never source URLs/paths. Reads are bounded and detect replacement, size and timestamp changes.
public protocol CaptureDataSource: Sendable {
    func describe() async throws -> CaptureSourceDescription
    func read(fileIndex: Int, offset: Int64, count: Int) async throws -> Data
}
public enum CaptureSourceError: Error, LocalizedError {
    case changed, limitExceeded, invalidRead
    public var errorDescription: String? {
        switch self {
        case .changed: "The saved capture changed while preparing or sending. Prepare the transfer again."
        case .limitExceeded: "This capture exceeds the supported transfer limits."
        case .invalidRead: "The capture file could not be read safely."
        }
    }
}
actor LocalCaptureDataSource: CaptureDataSource {
    private struct Stamp: Equatable {
        let size: Int64
        let modified: Date
        let inode: UInt64
    }
    private struct Entry {
        let path: String
        let url: URL
        let stamp: Stamp
        let digest: String
    }
    private let root: URL
    private let record: CaptureRecord
    private var entries: [Entry]?
    init(root: URL, record: CaptureRecord) { self.root = root; self.record = record }
    func describe() throws -> CaptureSourceDescription {
        if let entries {
            for entry in entries { try unchanged(entry) }
            return description(entries)
        }
        try checkDirectory(root)
        var candidates: [(String, URL)] = []; var itemCount = 0
        func visit(_ folder: URL, prefix: String) throws {
            try checkDirectory(folder)
            for url in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                try Task.checkCancellation()
                itemCount += 1
                guard itemCount <= CaptureSourceLimits.maximumFiles * 2 else { throw CaptureSourceError.limitExceeded }
                let path = prefix.isEmpty ? url.lastPathComponent : prefix + "/" + url.lastPathComponent
                guard path.utf8.count <= 1024 else { throw CaptureSourceError.limitExceeded }
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey])
                guard values.isSymbolicLink != true else { throw CaptureStorageError.unsafePath }
                if prefix.isEmpty {
                    guard path == "capture.json" || path == "Images" || path == "Checkpoints" else { throw CaptureStorageError.unsafePath }
                }
                if values.isDirectory == true { try visit(url, prefix: path) }
                else {
                    guard values.isRegularFile == true, candidates.count < CaptureSourceLimits.maximumFiles else { throw CaptureSourceError.limitExceeded }
                    candidates.append((path, url))
                }
            }
        }
        try visit(root, prefix: "")
        var prepared: [Entry] = []; var total: Int64 = 0
        for (path, url) in candidates {
            let before = try stamp(url)
            guard before.size >= 0, before.size <= CaptureSourceLimits.maximumFileBytes,
                  before.size <= CaptureSourceLimits.maximumTotalBytes - total else { throw CaptureSourceError.limitExceeded }
            total += before.size
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hash = SHA256(); var bytes: Int64 = 0; var metadata = Data()
            if path == "capture.json", before.size > 128 * 1024 { throw CaptureSourceError.limitExceeded }
            while let chunk = try handle.read(upToCount: CaptureSourceLimits.chunkBytes), !chunk.isEmpty {
                try Task.checkCancellation(); bytes += Int64(chunk.count)
                guard bytes <= before.size else { throw CaptureSourceError.changed }
                hash.update(data: chunk)
                if path == "capture.json" { metadata.append(chunk) }
            }
            guard bytes == before.size, try stamp(url) == before else { throw CaptureSourceError.changed }
            if path == "capture.json" {
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                guard try decoder.decode(CaptureRecord.self, from: metadata) == record else { throw CaptureSourceError.changed }
            }
            prepared.append(Entry(path: path, url: url, stamp: before, digest: hash.finalize().map { String(format: "%02x", $0) }.joined()))
        }
        entries = prepared; return description(prepared)
    }
    func read(fileIndex: Int, offset: Int64, count: Int) throws -> Data {
        guard let entries, entries.indices.contains(fileIndex), count > 0, count <= CaptureSourceLimits.chunkBytes,
              offset >= 0, offset <= entries[fileIndex].stamp.size else { throw CaptureSourceError.invalidRead }
        let entry = entries[fileIndex]; try unchanged(entry); try Task.checkCancellation()
        let handle = try FileHandle(forReadingFrom: entry.url); defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        let expected = Int(min(Int64(count), entry.stamp.size - offset))
        let bytes = try handle.read(upToCount: expected) ?? Data()
        guard bytes.count == expected else { throw CaptureSourceError.changed }
        try unchanged(entry); return bytes
    }
    private func description(_ entries: [Entry]) -> CaptureSourceDescription {
        CaptureSourceDescription(record: record, files: entries.map { CaptureSourceFile(path: $0.path, bytes: $0.stamp.size, sha256: $0.digest) })
    }
    private func unchanged(_ entry: Entry) throws {
        try checkDirectory(root)
        var parent = entry.url.deletingLastPathComponent()
        while parent.pathComponents.count >= root.pathComponents.count {
            try checkDirectory(parent)
            if parent.pathComponents.count == root.pathComponents.count { break }
            parent.deleteLastPathComponent()
        }
        guard try stamp(entry.url) == entry.stamp else { throw CaptureSourceError.changed }
    }
    private func checkDirectory(_ url: URL) throws { try OwnedFileSystem.validateDirectory(url) }
    private func stamp(_ url: URL) throws -> Stamp {
        let a = try FileManager.default.attributesOfItem(atPath: url.path)
        guard a[.type] as? FileAttributeType == .typeRegular,
              let size = a[.size] as? NSNumber, let date = a[.modificationDate] as? Date,
              let inode = a[.systemFileNumber] as? NSNumber else { throw CaptureStorageError.unsafePath }
        return Stamp(size: size.int64Value, modified: date, inode: inode.uint64Value)
    }
}
