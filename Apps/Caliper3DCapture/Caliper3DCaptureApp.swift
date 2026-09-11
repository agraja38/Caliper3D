import SwiftUI
import Caliper3DCore
import Caliper3DTransfer

@main
struct Caliper3DCaptureApp: App {
    private let demo = ProcessInfo.processInfo.arguments.contains("--demo-mode")
    var body: some Scene {
        WindowGroup { CaptureRootView(demo: demo) }
    }
}
struct CaptureRootView: View {
    let demo: Bool
    @AppStorage("onboardingComplete") private var onboarded = false
    var body: some View {
        if onboarded {
            if demo {
                CaptureHomeView(demo: true, capture: DemoCaptureService(), transfer: DemoTransferService())
            } else {
                ProductionCaptureHome(
                    repository: LocalCaptureRepository(root: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                        .resolvingSymlinksInPath()
                        .appendingPathComponent("Library/Application Support/Caliper3D/Captures", isDirectory: true)),
                    factory: ObjectCaptureFactory(), permission: CameraAuthorization())
            }
        } else { OnboardingView { onboarded = true } }
    }
}
struct OnboardingView: View {
    let finish: () -> Void
    @State private var page = 0
    var body: some View {
        VStack {
            TabView(selection: $page) {
                pageView("Turn your iPhone into a 3D scanner", symbol: "viewfinder", text: "Capture an object on iPhone, then reconstruct and refine it on your Mac.").tag(0)
                pageView("For best results", symbol: "light.max", text: "Use even lighting.\nKeep the object still.\nMove slowly and capture several angles.\nAvoid strong reflections.").tag(1)
                pageView("Connect to your Mac", symbol: "laptopcomputer.and.iphone", text: "Caliper3D will transfer scans directly over your local network. Secure pairing is coming soon; demo mode works without a connection.").tag(2)
            }.tabViewStyle(.page)
            Button(page == 2 ? "Get Started" : "Continue") {
                if page == 2 { finish() } else { withAnimation { page += 1 } }
            }.buttonStyle(.borderedProminent).controlSize(.large).padding(.bottom, 30)
        }
    }
    private func pageView(_ title: String, symbol: String, text: String) -> some View {
        VStack(spacing: 28) {
            Image(systemName: symbol).font(.system(size: 64, weight: .light)).foregroundStyle(.tint)
            Text(title).font(.title2).bold()
            Text(text).foregroundStyle(.secondary).lineSpacing(8)
        }.multilineTextAlignment(.center).padding(32)
    }
}
