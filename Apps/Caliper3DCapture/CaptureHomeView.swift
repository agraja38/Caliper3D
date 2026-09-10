import SwiftUI
import Caliper3DCore
import Caliper3DTransfer

struct CaptureHomeView: View {
    let demo: Bool
    @State private var model: CaptureFlowModel
    @State private var showFlow = false
    init(demo: Bool, capture: any CaptureService, transfer: any ScanTransferService) {
        self.demo = demo
        _model = State(initialValue: CaptureFlowModel(capture: capture, transfer: transfer))
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { showFlow = true; model.begin() } label: {
                        Label("New Scan", systemImage: "plus.viewfinder").font(.headline).padding(.vertical, 14)
                    }
                }
                Section("Recent Captures") {
                    if model.recent.isEmpty {
                        Text("Your captures will appear here.").foregroundStyle(.secondary)
                    }
                    ForEach(model.recent) { record in
                        Button { model.review(record); showFlow = true } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Label(record.name, systemImage: "cube")
                                Text("\(record.imageCount) simulated photos · demo").font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 4)
                        }
                    }
                    if demo { Text("Demo captures are temporary and reset when the app closes.").font(.caption).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Caliper3D Capture")
            .safeAreaInset(edge: .bottom) {
                Label(demo ? "Demo Mac · simulated connection" : "Mac pairing coming soon", systemImage: "laptopcomputer")
                    .font(.caption).foregroundStyle(.secondary).padding().frame(maxWidth: .infinity).background(.bar)
            }
            .sheet(isPresented: $showFlow, onDismiss: { model.cancel() }) {
                NavigationStack {
                    flow.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
                        .navigationTitle(demo ? "Demo Scan" : "New Scan")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { model.cancel(); showFlow = false } } }
                }
            }
        }
    }
    @ViewBuilder private var flow: some View {
        switch model.stage {
        case .ready: Text("Ready to scan")
        case .checking: ProgressView("Checking compatibility…")
        case .capturing:
            VStack(spacing: 24) {
                Image(systemName: "viewfinder").font(.system(size: 80, weight: .ultraLight))
                ProgressView("Simulating capture…")
                Text("No camera or LiDAR data is collected.").font(.caption).foregroundStyle(.secondary)
            }
        case .review:
            VStack(spacing: 24) {
                Image(systemName: "cube.transparent").font(.system(size: 90, weight: .ultraLight)).foregroundStyle(.tint)
                Text(model.current?.name ?? "Capture").font(.title2).bold()
                Text("48 simulated photos · no image files created").foregroundStyle(.secondary)
                Button("Simulate Transfer to Mac") { model.send() }.buttonStyle(.borderedProminent)
                Text("This previews the workflow. Nothing is sent over the network.").font(.caption).foregroundStyle(.secondary)
            }.multilineTextAlignment(.center)
        case .sending: ProgressView("Simulating local transfer…")
        case .sent:
            ContentUnavailableView("Demo transfer complete", systemImage: "checkmark.circle", description: Text("No data was sent. On your Mac, choose Try Demo Project to explore reconstruction."))
        case .unavailable(let message):
            ContentUnavailableView("Capture not available yet", systemImage: "iphone.slash", description: Text(message))
        case .failed(let message):
            VStack(spacing: 20) {
                ContentUnavailableView("Scan interrupted", systemImage: "exclamationmark.triangle", description: Text(message))
                Button("Try Again") { model.begin() }
            }
        }
    }
}
