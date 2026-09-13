import Foundation

/// Checks app-owned paths before filesystem mutations. Only Darwin's exact system aliases
/// are permitted; this does not authorize arbitrary paths from a peer or replace UUID ownership.
public enum OwnedFileSystem {
    public static func validateAncestors(_ url: URL) throws {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.pathComponents.contains("..") else { throw CaptureStorageError.unsafePath }
        var parts = url.path.split(separator: "/").map(String.init)
        while !parts.isEmpty {
            let path = "/" + parts.joined(separator: "/")
            if let attributes = try? FileManager.default.attributesOfItem(atPath: path),
               attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                let destination = try FileManager.default.destinationOfSymbolicLink(atPath: path)
                guard let expected = ["/var": "private/var", "/tmp": "private/tmp"][path],
                      destination == expected || destination == "/" + expected else { throw CaptureStorageError.unsafePath }
            }
            parts.removeLast()
        }
    }
    public static func validateDirectory(_ url: URL) throws {
        try validateAncestors(url)
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw CaptureStorageError.unsafePath }
    }
    public static func createDirectory(_ url: URL) throws {
        try validateAncestors(url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try validateDirectory(url)
    }
}
