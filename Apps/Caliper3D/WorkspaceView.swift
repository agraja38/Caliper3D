import SwiftUI
import Caliper3DCore
import Caliper3DTransfer

private enum Destination: String, CaseIterable, Identifiable {
    case library = "Library", newScan = "New Scan", devices = "Devices", processing = "Processing"
    var id: Self { self }
    var symbol: String {
        switch self {
        case .library: "square.stack.3d.up"
        case .newScan: "plus.viewfinder"
        case .devices: "iphone"
        case .processing: "gearshape.2"
        }
    }
}
struct WorkspaceView: View {
    let demo: Bool
    @State private var destination: Destination? = .library
    @State private var library: LibraryModel
    @State private var jobs = ProcessingModel(service: DemoPhotogrammetryService())
    init(demo: Bool) {
        self.demo = demo
        let root = URL.applicationSupportDirectory.appendingPathComponent("Caliper3D")
            .appendingPathComponent(demo ? "DemoProjects" : "Projects")
        _library = State(initialValue: LibraryModel(store: LocalProjectStore(root: root)))
    }
    var body: some View {
        NavigationSplitView {
            List(Destination.allCases, selection: $destination) { item in
                Label(item.rawValue, systemImage: item.symbol).tag(item)
            }
            .navigationTitle("Caliper3D")
            .safeAreaInset(edge: .bottom) {
                if demo { Label("Demo mode", systemImage: "testtube.2").font(.caption).foregroundStyle(.secondary).padding() }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            switch destination ?? .library {
            case .library:
                if let project = library.selection {
                    ProjectEditor(project: project, jobs: jobs) { library.selection = nil }
                } else if library.projects.isEmpty { welcome }
                else {
                    List(library.projects) { project in
                        Button {
                            library.selection = project
                        } label: {
                            HStack {
                                Image(systemName: "cube.transparent").font(.title2).frame(width: 36)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(project.manifest.name).foregroundStyle(.primary)
                                    Text("\(project.manifest.imageCount) photos · \(project.manifest.captureMethod.rawValue)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(project.manifest.modifiedAt, style: .date).foregroundStyle(.secondary)
                            }.padding(.vertical, 6).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        .accessibilityAction { library.selection = project }
                        .contextMenu { Button("Open Project") { library.selection = project } }
                    }.navigationTitle("Library")
                    .toolbar { Button("New Scan", systemImage: "plus") { destination = .newScan }.help("Start a new project") }
                }
            case .newScan: welcome
            case .devices:
                DevicesView(service: demo ? DemoDiscoveryService() : UnavailableDiscoveryService(), demo: demo)
            case .processing: ProcessingView(model: jobs)
            }
        }
        .task { await library.load() }
        .onOpenURL { url in Task { await library.openProject(at: url); destination = .library } }
        .toolbar {
            ToolbarItemGroup {
                Button("Open", systemImage: "folder") { Task { await library.openProject(); destination = .library } }
                    .keyboardShortcut("o").help("Open a .caliper3d project")
                Button("Import Photos", systemImage: "photo.on.rectangle") { Task { await library.importPhotos(); destination = .library } }
                    .keyboardShortcut("i", modifiers: [.command, .shift]).disabled(library.isBusy)
            }
        }
        .alert("Unable to complete action", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) {
            Button("OK") { library.error = nil }
        } message: { Text(library.error ?? "") }
    }
    private var welcome: some View {
        VStack(spacing: 20) {
            Image(systemName: "viewfinder").font(.system(size: 46, weight: .light)).foregroundStyle(.secondary)
            Text("Scan real objects with your iPhone").font(.title2).fontWeight(.semibold)
            Text("Capture on iPhone. Shape the result on your Mac.").foregroundStyle(.secondary)
            VStack(spacing: 10) {
                Button("Set Up iPhone") { destination = .devices }.buttonStyle(.borderedProminent)
                Button("Open Existing Scan") { Task { await library.openProject(); destination = .library } }
                Button("Import Photos") { Task { await library.importPhotos(); destination = .library } }
                Button("Try Demo Project") { Task { await library.createDemo(); destination = .library } }
            }.controlSize(.large).disabled(library.isBusy)
            if library.isBusy { ProgressView().controlSize(.small) }
            Text("Local by design. Your scans stay with you.").font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(32)
        .navigationTitle("New Scan")
    }
}
