import SwiftUI
import Caliper3DCore

struct ProductionCaptureHome: View {
    let repository: any CaptureRepository
    let factory: any CaptureSessionFactory
    let permission: any CameraPermissionService
    @State private var library = CaptureLibrary()
    @State private var scanner: CaptureSessionModel?
    @State private var selected: CaptureRecord?
    @State private var pendingReview: CaptureRecord?
    @State private var error: String?
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        scanner = CaptureSessionModel(factory: factory, permission: permission, repository: repository)
                    } label: { Label("New Scan", systemImage: "plus.viewfinder").font(.headline).padding(.vertical, 14) }
                }
                Section("Recent Captures") {
                    if library.completed.isEmpty { Text("Your saved captures will appear here.").foregroundStyle(.secondary) }
                    ForEach(library.completed) { record in
                        Button { selected = record } label: { CaptureRow(record: record) }.tint(.primary)
                    }
                }
                if !library.incomplete.isEmpty {
                    Section {
                        ForEach(library.incomplete) { record in
                            Button { selected = record } label: { CaptureRow(record: record) }.tint(.primary)
                        }
                    } header: { Text("Incomplete Captures") }
                    footer: { Text("Files from interrupted scans are preserved. These scans cannot be resumed after relaunch; inspect their status or delete them when no longer needed.") }
                }
                if library.unreadableCount > 0 {
                    Text("\(library.unreadableCount) capture folders could not be read. Their files have been preserved.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Caliper3D Capture")
            .safeAreaInset(edge: .bottom) {
                Label("Mac connection coming next", systemImage: "laptopcomputer")
                    .font(.caption).foregroundStyle(.secondary).padding().frame(maxWidth: .infinity).background(.bar)
            }
            .refreshable { await reload() }
            .task { await reload() }
            .fullScreenCover(isPresented: Binding(get: { scanner != nil }, set: { if !$0 { scanner = nil } }), onDismiss: { selected = pendingReview; pendingReview = nil; Task { await reload() } }) {
                if let scanner {
                    LiveCaptureView(model: scanner) { record in
                        self.scanner = nil
                        pendingReview = record
                    }
                }
            }
            .sheet(item: $selected, onDismiss: { Task { await reload() } }) { record in
                SavedCaptureReview(record: record, repository: repository)
            }
            .alert("Capture storage", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
        }
    }
    private func reload() async {
        do { library = try await repository.library() }
        catch { self.error = error.localizedDescription }
    }
}
struct CaptureRow: View {
    let record: CaptureRecord
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(record.name, systemImage: record.status == .ready ? "cube" : "exclamationmark.circle")
                .font(.headline)
            if let date = record.createdAt { Text(date, style: .date).font(.caption).foregroundStyle(.secondary) }
            Text(record.status == .ready ? "\(record.imageCount) \(record.imageCount == 1 ? "photo" : "photos") · \(ByteCountFormatter.string(fromByteCount: record.totalBytes ?? 0, countStyle: .file)) · Ready to send" : "Incomplete · files preserved")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 4)
    }
}
struct SavedCaptureReview: View {
    @State var record: CaptureRecord
    let repository: any CaptureRepository
    @Environment(\.dismiss) private var dismiss
    @State private var preview: Data?
    @State private var name = ""
    @State private var renaming = false
    @State private var deleting = false
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let preview, let image = UIImage(data: preview) {
                        Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 250)
                            .accessibilityLabel("Preview of a saved capture photo")
                    }
                    Label(record.name, systemImage: "cube").font(.title2).bold()
                    if let date = record.createdAt { Text(date.formatted(date: .long, time: .shortened)).foregroundStyle(.secondary) }
                    if record.status == .ready {
                        Text("\(record.imageCount) \(record.imageCount == 1 ? "photo" : "photos") captured").font(.headline)
                        Text(ByteCountFormatter.string(fromByteCount: record.totalBytes ?? 0, countStyle: .file))
                        Label("Ready to send", systemImage: "checkmark.circle").foregroundStyle(.green)
                        Text("Mac connection coming next. Your capture is saved on this iPhone.").foregroundStyle(.secondary)
                    } else {
                        Label("Incomplete capture", systemImage: "exclamationmark.circle")
                        Text("The scan did not finish. Any images and checkpoints remain on this iPhone. Restarting a saved incomplete session is not supported yet.")
                            .foregroundStyle(.secondary)
                    }
                    Button("Save for Later") { dismiss() }.buttonStyle(.borderedProminent)
                    Button("Rename", systemImage: "pencil") { name = record.name; renaming = true }
                    Button("Delete Capture", systemImage: "trash", role: .destructive) { deleting = true }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
            }
            .navigationTitle("Capture Review").navigationBarTitleDisplayMode(.inline)
            .task(id: record.id) { preview = try? await repository.previewJPEG(record.id) }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(busy) } }
            .disabled(busy).interactiveDismissDisabled(busy)
            .alert("Rename Capture", isPresented: $renaming) {
                TextField("Name", text: $name)
                Button("Cancel", role: .cancel) {}
                Button("Save") { Task { await rename() } }
            }
            .confirmationDialog("Delete this capture and all of its files?", isPresented: $deleting, titleVisibility: .visible) {
                Button("Delete Capture", role: .destructive) { Task { await delete() } }
            } message: { Text("This cannot be undone. Other captures will not be changed.") }
            .alert("Capture storage", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
        }
    }
    private func rename() async {
        busy = true; defer { busy = false }
        do { record = try await repository.rename(record.id, name: name) }
        catch { self.error = error.localizedDescription }
    }
    private func delete() async {
        busy = true; defer { busy = false }
        do { try await repository.delete(record.id); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}
