import Foundation
import CryptoKit

public enum TransferPolicy {
    public static let protocolVersion = 1
    public static let bonjourType = "_caliper3d._tcp"
    public static let maximumControlBytes = 4 * 1024 * 1024
    public static let chunkBytes = 256 * 1024
    public static let receiveBytes = chunkBytes
    public static let maximumFiles = 10_000
    public static let maximumFileBytes: Int64 = 16 * 1024 * 1024 * 1024
    public static let maximumTotalBytes: Int64 = 128 * 1024 * 1024 * 1024
    public static let maximumPathBytes = 1024
    public static let maximumComponentBytes = 255
    public static func digest(_ data: Data) -> String { hex(SHA256.hash(data: data)) }
    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
    static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func validText(_ text: String, maximum: Int) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf8.count <= maximum
            && !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
    public static func isSafeRelativePath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !path.isEmpty && path.utf8.count <= maximumPathBytes
            && path.utf8.elementsEqual(path.precomposedStringWithCanonicalMapping.utf8)
            && !path.contains("\\") && !path.contains(":") && !path.contains("%")
            && !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= maximumComponentBytes
                && !$0.hasSuffix(" ") && !$0.hasSuffix(".") }
    }
    static func collisionKey(_ path: String) -> String {
        path.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}
public struct TransferFile: Codable, Equatable, Sendable {
    public let path: String
    public let bytes: Int64
    public let sha256: String
    public init(path: String, bytes: Int64, sha256: String) { self.path = path; self.bytes = bytes; self.sha256 = sha256 }
}
public struct TransferSource: Codable, Equatable, Sendable {
    public let name: String
    public let operatingSystem: String
    public let objectCaptureSupported: Bool
    public init(name: String, operatingSystem: String, objectCaptureSupported: Bool) {
        self.name = name; self.operatingSystem = operatingSystem; self.objectCaptureSupported = objectCaptureSupported
    }
}
public struct TransferManifest: Codable, Equatable, Sendable {
    public let version: Int
    public let transferID: UUID
    public let captureID: UUID
    public let name: String
    /// ISO-8601 UTC timestamp, independent of Swift Date encoding defaults.
    public let createdAt: String
    public let source: TransferSource
    public let imageCount: Int
    public let totalBytes: Int64
    public let files: [TransferFile]
    public init(transferID: UUID, captureID: UUID, name: String, createdAt: String, source: TransferSource,
                imageCount: Int, totalBytes: Int64, files: [TransferFile]) {
        version = TransferPolicy.protocolVersion; self.transferID = transferID; self.captureID = captureID
        self.name = name; self.createdAt = createdAt; self.source = source; self.imageCount = imageCount
        self.totalBytes = totalBytes; self.files = files
    }
    public func validate() throws {
        guard version == TransferPolicy.protocolVersion else { throw WireError.unsupportedVersion(version) }
        guard TransferPolicy.validText(name, maximum: 480), createdAt.utf8.count <= 32,
              createdAt.hasSuffix("Z"), ISO8601DateFormatter().date(from: createdAt) != nil,
              TransferPolicy.validText(source.name, maximum: 256), TransferPolicy.validText(source.operatingSystem, maximum: 128),
              source.objectCaptureSupported, imageCount > 0, imageCount <= TransferPolicy.maximumFiles,
              !files.isEmpty, files.count <= TransferPolicy.maximumFiles,
              totalBytes > 0, totalBytes <= TransferPolicy.maximumTotalBytes else { throw WireError.invalidManifest }
        var keys = Set<String>(); var sum: Int64 = 0; var images = 0
        for file in files {
            guard TransferPolicy.isSafeRelativePath(file.path),
                  file.path == "capture.json" || file.path.hasPrefix("Images/") || file.path.hasPrefix("Checkpoints/") else { throw WireError.unsafePath }
            guard file.bytes >= 0, file.bytes <= TransferPolicy.maximumFileBytes,
                  TransferPolicy.isSHA256(file.sha256) else { throw WireError.invalidManifest }
            let key = TransferPolicy.collisionKey(file.path)
            guard keys.insert(key).inserted else { throw WireError.unsafePath }
            let (next, overflow) = sum.addingReportingOverflow(file.bytes)
            guard !overflow, next <= TransferPolicy.maximumTotalBytes else { throw WireError.invalidManifest }; sum = next
            let parts = file.path.split(separator: "/")
            if parts.count == 2, parts[0] == "Images", ["heic", "heif", "jpg", "jpeg", "png"].contains((file.path as NSString).pathExtension.lowercased()) {
                guard file.bytes > 0 else { throw WireError.invalidManifest }; images += 1
            }
        }
        // Reject file-vs-directory collisions, including case/Unicode aliases on Apple filesystems.
        for key in keys {
            var parts = key.split(separator: "/"); parts.removeLast()
            while !parts.isEmpty {
                guard !keys.contains(parts.joined(separator: "/")) else { throw WireError.unsafePath }
                parts.removeLast()
            }
        }
        guard files.contains(where: { $0.path == "capture.json" && $0.bytes > 0 && $0.bytes <= Int64(TransferPolicy.maximumControlBytes) }),
              sum == totalBytes, images == imageCount else { throw WireError.invalidManifest }
    }
    /// Protocol-defined sorted JSON representation; array order determines stable file indices.
    public func canonicalData() throws -> Data {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        // Leave envelope overhead available in the enclosing transferOffer.
        guard data.count <= TransferPolicy.maximumControlBytes - 1024 else { throw WireError.oversizedFrame }
        return data
    }
    public func digest() throws -> String { TransferPolicy.digest(try canonicalData()) }
}

/// Incremental verification, independent of disk/network. Completion alone permits marking a file verified.
public struct FileIntegrityVerifier: Sendable {
    private let expected: TransferFile
    private var hasher = SHA256()
    public private(set) var receivedBytes: Int64 = 0
    private var terminal = false
    public init(file: TransferFile) throws {
        guard file.bytes >= 0, file.bytes <= TransferPolicy.maximumFileBytes, TransferPolicy.isSHA256(file.sha256) else { throw WireError.invalidManifest }
        expected = file
    }
    public mutating func consume(_ bytes: Data) throws {
        guard !terminal, bytes.count <= TransferPolicy.chunkBytes,
              Int64(bytes.count) <= expected.bytes - receivedBytes else { terminal = true; throw WireError.integrityMismatch }
        hasher.update(data: bytes); receivedBytes += Int64(bytes.count)
    }
    public mutating func finish() throws {
        guard !terminal else { throw WireError.integrityMismatch }
        terminal = true
        guard receivedBytes == expected.bytes, TransferPolicy.hex(hasher.finalize()) == expected.sha256 else { throw WireError.integrityMismatch }
    }
}
