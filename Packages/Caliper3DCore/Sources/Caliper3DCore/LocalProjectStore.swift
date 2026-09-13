import Foundation

/// Owns package mutations. Imported originals are copied; future edits belong in processed/.
public actor LocalProjectStore: ScanProjectStore {
    private let root: URL
    private let incomingRoot: URL
    private let files = FileManager.default
    public init(root: URL, incomingRoot: URL? = nil) {
        self.root = root; self.incomingRoot = incomingRoot ?? root.deletingLastPathComponent().appendingPathComponent("Incoming")
    }
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
    /// Resolves staging by UUID inside the configured Incoming root, never a peer-supplied URL.
    public func finalizeReceivedCapture(transferID: UUID, record: CaptureRecord, expectedFiles: [CaptureSourceFile], datasetDigest: String) async throws -> ReceivedProjectResult {
        try record.validateReal()
        guard record.status == .ready, !record.isDemo, let created = record.createdAt else { throw ProjectError.invalidManifest }
        let source = incomingRoot.appendingPathComponent(transferID.uuidString + ".partial").appendingPathComponent("dataset")
        try OwnedFileSystem.validateDirectory(source)
        try OwnedFileSystem.createDirectory(root)
        let destination = root.appendingPathComponent(record.id.uuidString + ".caliper3d")
        if FileManager.default.fileExists(atPath: destination.path) {
            let project = try open(destination)
            guard project.manifest.sourceCaptureDigest == datasetDigest else { throw ReceivedProjectError.conflict }
            try await verifyReceivedFiles(destination.appendingPathComponent("capture"), record: record, expected: expectedFiles)
            return .duplicate(project)
        }
        var manifest = ScanManifest(id: record.id, name: record.name, captureMethod: .objectCapture, imageCount: record.imageCount,
            sourceDevice: record.sourceDevice.map { SourceDevice(name: $0.name, operatingSystem: $0.operatingSystem, hasLiDAR: nil) })
        manifest.createdAt = created; manifest.sourceCaptureDigest = datasetDigest
        let metadata = try ManifestCodec.encode(manifest)
        let staging = root.appendingPathComponent(".staging-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }
        // Copy keeps resumable verified input intact until the final atomic move succeeds.
        try await verifyReceivedFiles(source, record: record, expected: expectedFiles)
        try FileManager.default.copyItem(at: source, to: staging.appendingPathComponent("capture"))
        for folder in ["reconstruction", "processed", "thumbnails", "logs"] {
            try FileManager.default.createDirectory(at: staging.appendingPathComponent(folder), withIntermediateDirectories: false)
        }
        try await verifyReceivedFiles(staging.appendingPathComponent("capture"), record: record, expected: expectedFiles)
        try metadata.write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)
        // Actor reentrancy may allow another finalization while hashes run; never replace its result.
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw ReceivedProjectError.conflict }
        try FileManager.default.moveItem(at: staging, to: destination)
        return .created(ScanProject(manifest: manifest, url: destination))
    }
    private func verifyReceivedFiles(_ folder: URL, record: CaptureRecord, expected: [CaptureSourceFile]) async throws {
        let snapshot = try await LocalCaptureDataSource(root: folder, record: record).describe()
        guard snapshot.files.sorted(by: { $0.path < $1.path }) == expected.sorted(by: { $0.path < $1.path }) else { throw ReceivedProjectError.changed }
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

public enum ReceivedProjectError: Error, LocalizedError {
    case conflict, changed
    public var errorDescription: String? {
        switch self {
        case .conflict: "A project with this capture ID already exists with different data. It was not overwritten."
        case .changed: "The staged capture changed during final verification. Retry the transfer."
        }
    }
}
public enum ReceivedProjectResult: Sendable {
    case created(ScanProject), duplicate(ScanProject)
    public var project: ScanProject { switch self { case .created(let project), .duplicate(let project): project } }
}
