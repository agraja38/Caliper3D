import Foundation

/// Owns package mutations. Imported originals are copied; future edits belong in processed/.
public actor LocalProjectStore: ScanProjectStore {
    private let root: URL
    private let files = FileManager.default
    public init(root: URL) { self.root = root }
    public func list() throws -> [ScanProject] {
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        return try files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "caliper3d" }
            .map { try open($0) }
            .sorted { $0.manifest.modifiedAt > $1.manifest.modifiedAt }
    }
    public func create(_ manifest: ScanManifest) throws -> ScanProject {
        try persist(manifest, images: [])
    }
    public func importPhotos(_ urls: [URL], name: String) throws -> ScanProject {
        guard (1...500).contains(urls.count) else { throw ProjectError.tooManyImages }
        for url in urls {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard ["jpg", "jpeg", "heic", "png"].contains(url.pathExtension.lowercased()),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size > 0, size <= 100_000_000 else { throw ProjectError.unsupportedImage }
        }
        return try persist(ScanManifest(name: name, captureMethod: .importedPhotos, imageCount: urls.count), images: urls)
    }
    public func open(_ url: URL) throws -> ScanProject {
        guard url.pathExtension == "caliper3d" else { throw ProjectError.unsafePackage }
        let rootValues = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else { throw ProjectError.unsafePackage }
        let manifestURL = url.appendingPathComponent("manifest.json")
        let values = try manifestURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= 1_000_000 else { throw ProjectError.unsafePackage }
        return ScanProject(manifest: try ManifestCodec.decode(Data(contentsOf: manifestURL)), url: url)
    }
    private func persist(_ manifest: ScanManifest, images: [URL]) throws -> ScanProject {
        let data = try ManifestCodec.encode(manifest)
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent(manifest.id.uuidString).appendingPathExtension("caliper3d")
        let staging = root.appendingPathComponent(".staging-" + UUID().uuidString)
        try files.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: staging) }
        for folder in ["capture", "reconstruction", "processed", "thumbnails", "logs"] {
            try files.createDirectory(at: staging.appendingPathComponent(folder), withIntermediateDirectories: false)
        }
        for (index, url) in images.enumerated() {
            try Task.checkCancellation()
            let filename = String(format: "%05d", index) + "." + url.pathExtension.lowercased()
            try files.copyItem(at: url, to: staging.appendingPathComponent("capture").appendingPathComponent(filename))
        }
        try data.write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)
        try files.moveItem(at: staging, to: destination)
        AppLog.filesystem.info("Created local project package")
        return ScanProject(manifest: manifest, url: destination)
    }
}
