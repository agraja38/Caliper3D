import SwiftUI
import RealityKit
import Caliper3DCore

struct ProjectEditor: View {
    let project: ScanProject
    let jobs: ProcessingModel
    let close: () -> Void
    @State private var inspector = false
    @State private var rotation: Double = 25
    @State private var scale: Double = 1
    @AppStorage("preferredUnits") private var units = LengthUnit.millimeters.rawValue
    var body: some View {
        VStack(spacing: 0) {
            if project.manifest.captureMethod == .demo {
                DemoViewport(rotation: rotation, scale: scale)
                .overlay(alignment: .bottom) {
                    HStack {
                        Label("Rotate", systemImage: "rotate.3d").font(.caption)
                        Slider(value: $rotation, in: -180...180).frame(width: 150).accessibilityLabel("Model rotation")
                        Label("Zoom", systemImage: "magnifyingglass").font(.caption)
                        Slider(value: $scale, in: 0.5...1.5).frame(width: 100).accessibilityLabel("Model zoom")
                        Button("Reset") { rotation = 25; scale = 1 }.help("Reset the demo view")
                    }.padding(12).background(.regularMaterial).padding()
                }
                .accessibilityLabel("Synthetic calibration block, 80 by 60 by 40 millimeters")
            } else {
                ContentUnavailableView("Photos ready", systemImage: "photo.stack", description: Text("\(project.manifest.imageCount) source photos. RealityKit reconstruction is the next Mac processing milestone."))
            }
            Divider()
            HStack {
                Text(project.manifest.captureMethod == .demo ? "Synthetic demo geometry · not a reconstructed scan" : "Original photos preserved")
                Spacer()
                if jobs.isRunning(project.id) { ProgressView().controlSize(.mini); Text("Simulating…") }
            }.font(.caption).foregroundStyle(.secondary).padding(10)
        }
        .navigationTitle(project.manifest.name)
        .toolbar {
            Button("Library", systemImage: "chevron.left", action: close).help("Return to the library")
            if project.manifest.captureMethod == .demo {
                Button("Simulate Reconstruction", systemImage: "gearshape.2") { jobs.start(project) }
                    .disabled(jobs.isRunning(project.id)).help("Run an explicitly simulated processing job")
            }
            Button("Project Info", systemImage: "sidebar.right") { inspector.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option]).help("Show project information")
        }
        .inspector(isPresented: $inspector) {
            Form {
                Section("Project") {
                    LabeledContent("Name", value: project.manifest.name)
                    LabeledContent("Photos", value: String(project.manifest.imageCount))
                    LabeledContent("Method", value: project.manifest.captureMethod.rawValue)
                    LabeledContent("Schema", value: String(project.manifest.schemaVersion))
                }
                if let d = project.manifest.dimensions {
                    Section("Reference dimensions") {
                        Text(dimensionText(d))
                        Text("Synthetic reference, not a measured result.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.formStyle(.grouped).inspectorColumnWidth(min: 240, ideal: 270, max: 330)
        }
    }
    private func dimensionText(_ d: Dimensions) -> String {
        let unit = LengthUnit(rawValue: units) ?? .millimeters
        let divisor: Double = unit == .meters ? 1000 : unit == .centimeters ? 10 : 1
        return String(format: "%.1f × %.1f × %.1f %@", d.width / divisor, d.height / divisor, d.depth / divisor, unit.rawValue)
    }
}
