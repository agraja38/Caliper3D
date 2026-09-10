import SwiftUI
import Caliper3DCore
import Caliper3DTransfer

@main
struct Caliper3DApp: App {
    private let demo = ProcessInfo.processInfo.arguments.contains("--demo-mode")
    var body: some Scene {
        WindowGroup {
            WorkspaceView(demo: demo)
                .frame(minWidth: 850, minHeight: 560)
        }
        .defaultSize(width: 1100, height: 740)
        Settings { PreferencesView() }
    }
}
struct PreferencesView: View {
    @AppStorage("preferredUnits") private var units = LengthUnit.millimeters.rawValue
    var body: some View {
        Form {
            Picker("Display units", selection: $units) {
                ForEach(LengthUnit.allCases, id: \.rawValue) { Text($0.rawValue.capitalized).tag($0.rawValue) }
            }
            Text("Projects stay on this Mac. No accounts, analytics or cloud services.")
                .font(.callout).foregroundStyle(.secondary)
        }.padding(24).frame(width: 420)
    }
}
