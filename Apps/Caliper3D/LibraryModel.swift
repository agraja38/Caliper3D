import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Caliper3DCore

@MainActor @Observable
final class LibraryModel {
    var projects: [ScanProject] = []
    var selection: ScanProject?
    var error: String?
    var isBusy = false
    private let store: any ScanProjectStore
    init(store: any ScanProjectStore) { self.store = store }
    func load() async {
        do { projects = try await store.list() }
        catch { self.error = error.localizedDescription }
    }
    func createDemo() async {
        guard !isBusy else { return }
        isBusy = true; defer { isBusy = false }
        do {
            var manifest = ScanManifest(name: "Demo · Calibration Block", captureMethod: .demo)
            manifest.dimensions = Dimensions(width: 80, height: 60, depth: 40)
            let project = try await store.create(manifest)
            projects.insert(project, at: 0); selection = project
        } catch { self.error = error.localizedDescription }
    }
    func openProject() async {
        let panel = NSOpenPanel()
        panel.title = "Open Caliper3D Project"; panel.canChooseDirectories = true
        panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "caliper3d") ?? .package]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        await openProject(at: url)
    }
    func openProject(at url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let project = try await store.open(url)
            if !projects.contains(where: { $0.id == project.id }) { projects.insert(project, at: 0) }
            selection = project
        } catch { self.error = error.localizedDescription }
    }
    func importPhotos() async {
        let panel = NSOpenPanel()
        panel.title = "Import Object Photos"; panel.allowedContentTypes = [.jpeg, .heic, .png]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { for url in scoped { url.stopAccessingSecurityScopedResource() } }
        isBusy = true; defer { isBusy = false }
        do {
            let project = try await store.importPhotos(urls, name: "Imported Photos")
            projects.insert(project, at: 0); selection = project
        } catch { self.error = error.localizedDescription }
    }
}
