import SwiftUI
import RealityKit
import Caliper3DCore

struct LiveCaptureView: View {
    let model: CaptureSessionModel
    let close: (CaptureRecord?) -> Void
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var cancelRequested = false
    @State private var coverage = false
    @State private var closing = false
    var body: some View {
        NavigationStack {
            content
                .navigationTitle("New Scan").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(model.stage == .live ? "Cancel" : "Close") {
                            if model.stage == .live { cancelRequested = true }
                            else { Task { await dismissCapture() } }
                        }.disabled(model.stage == .saving || closing || model.snapshot.phase == .finishing)
                    }
                }
                .confirmationDialog("Stop this scan?", isPresented: $cancelRequested, titleVisibility: .visible) {
                    Button("Stop Scan", role: .destructive) { Task { await dismissCapture() } }
                } message: { Text("Incomplete files will be preserved on this iPhone. Saved captures are not affected.") }
                .task { await model.begin() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background || (phase == .inactive && model.stage == .live) { model.pause() }
                }
                .onChange(of: cancelRequested) { _, requested in if requested { model.pause() } }
                .onChange(of: model.stage) { _, stage in
                    if stage == .review {
                        let record = model.record
                        model.releaseCompletedSession()
                        close(record)
                    }
                }
                .sheet(isPresented: $coverage, onDismiss: { /* Require an explicit Resume after review. */ }) {
                    if let driver = model.driver as? ObjectCaptureDriver {
                        NavigationStack {
                            Group {
                                if #available(iOS 18.0, *) { ObjectCapturePointCloudView(session: driver.session).showShotLocations(true) }
                                else { ObjectCapturePointCloudView(session: driver.session) }
                            }
                            .navigationTitle("Capture Coverage").navigationBarTitleDisplayMode(.inline)
                            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { coverage = false } } }
                        }
                    }
                }
        }
        .interactiveDismissDisabled()
    }
    @ViewBuilder private var content: some View {
        switch model.stage {
        case .idle, .checking: ProgressView("Preparing camera…")
        case .unsupported:
            ContentUnavailableView("3D scanning isn’t available on this iPhone", systemImage: "iphone.slash", description: Text("Caliper3D requires an iPhone supported by Apple’s Object Capture system. In Simulator, run the Caliper3DCapture Demo scheme to explore the workflow."))
        case .permissionDenied:
            VStack(spacing: 16) {
                ContentUnavailableView("Camera access is required", systemImage: "camera", description: Text("Caliper3D uses the camera to capture the object you choose. Allow camera access in Settings, then start a new scan."))
                Button("Open Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) } }
                    .buttonStyle(.borderedProminent)
            }.padding()
        case .permissionRestricted:
            ContentUnavailableView("Camera access is restricted", systemImage: "camera", description: Text("This iPhone’s restrictions prevent camera use. Check with the person managing the device."))
        case .live:
            if let driver = model.driver as? ObjectCaptureDriver {
                ObjectCaptureView(session: driver.session)
                    .safeAreaInset(edge: .bottom) { controls.padding().background(.regularMaterial) }
            }
        case .saving: ProgressView("Checking and saving capture files…")
        case .review: ProgressView("Opening saved capture…")
        case .failed(let message):
            ContentUnavailableView("Capture interrupted", systemImage: "exclamationmark.triangle", description: Text(message + "\nAny incomplete files have been preserved."))
        case .storageFailure(let message):
            VStack(spacing: 16) {
                ContentUnavailableView("Capture storage needs attention", systemImage: "externaldrive.badge.exclamationmark", description: Text(message))
                if model.canRetrySave { Button("Retry Saving") { Task { await model.retrySave() } }.buttonStyle(.borderedProminent) }
            }.padding()
        case .cancelled: Text("Scan stopped")
        }
    }
    private var controls: some View {
        VStack(spacing: 10) {
            if model.snapshot.shots > 0 { Text("\(model.snapshot.shots) \(model.snapshot.shots == 1 ? "photo" : "photos") captured").font(.subheadline.monospacedDigit()) }
            if let guidance = model.message ?? model.snapshot.guidance {
                Text(guidance).font(.callout).multilineTextAlignment(.center)
            }
            if model.flipPending {
                Text("Gently flip the object to show another side. Then select it again.").font(.callout)
                Button("Object Is Flipped") { model.confirmFlip() }.buttonStyle(.borderedProminent)
                Button("Keep Current Position") { model.cancelFlip() }
            } else if model.snapshot.paused {
                Text("Scan paused").font(.headline)
                Button("Resume Scan") { model.resume() }.buttonStyle(.borderedProminent)
            } else {
                switch model.snapshot.phase {
                case .initializing: ProgressView("Starting Object Capture…")
                case .ready:
                    Button("Start Detection") { model.detect() }.buttonStyle(.borderedProminent)
                case .detecting:
                    Text("Adjust the selection around your object.").font(.callout)
                    Button("Start Capturing") { model.capture() }.buttonStyle(.borderedProminent).disabled(!model.snapshot.canCapture)
                    Button("Reset Selection") { model.resetDetection() }
                case .capturing:
                    if model.snapshot.passCompleted {
                        Text("Scan pass complete").font(.headline)
                        Button("Finish Scan") { model.finish() }.buttonStyle(.borderedProminent).disabled(!model.snapshot.canFinish)
                        Menu("Add Another Pass") {
                            Button("Another Angle — Keep Object Still") { model.nextPass() }
                            if !model.snapshot.feedback.contains(.notFlippable) {
                                Button("Flip Object to Scan Another Side") { model.prepareFlip() }
                            }
                        }
                    } else {
                        Button("Finish Scan") { model.finish() }.buttonStyle(.borderedProminent).disabled(!model.snapshot.canFinish)
                    }
                    if model.snapshot.shots > 0 {
                        Button("Review Coverage", systemImage: "cube.transparent") { model.pause(); coverage = true }
                    }
                case .finishing: ProgressView("Finishing capture…")
                case .completed, .failed: EmptyView()
                }
            }
        }.frame(maxWidth: .infinity)
    }
    private func dismissCapture() async {
        closing = true
        await model.cancel()
        closing = false
        close(nil)
    }
}
