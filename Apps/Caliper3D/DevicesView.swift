import SwiftUI
import Caliper3DTransfer

struct DevicesView: View {
    let service: any DeviceDiscoveryService
    let demo: Bool
    @State private var devices: [DiscoveredDevice] = []
    @State private var error: String?
    var body: some View {
        Form {
            if devices.isEmpty {
                Section("Set up Caliper3D Capture") {
                    Text("Build the iPhone target in Xcode and run it on your iPhone. A personal signing team is required for physical devices.")
                    Text("Automatic installation and secure Mac pairing are planned. No network listener is active in this release.")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(devices) { device in
                Section(device.name) {
                    LabeledContent("Connection", value: "Simulated connection")
                    LabeledContent("System", value: device.operatingSystem)
                    LabeledContent("LiDAR", value: device.hasLiDAR == true ? "Available (simulated)" : "Unknown")
                    LabeledContent("Capture app", value: "Installed (simulated)")
                    LabeledContent("Provisioning", value: "Not checked")
                }
            }
            Section("Development") {
                Text("Run either app with --demo-mode to explore capture, transfer and reconstruction without a LiDAR iPhone.")
                if demo { Text("Demo services do not discover or communicate with real devices.").foregroundStyle(.secondary) }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }.formStyle(.grouped).navigationTitle("Devices")
            .task { await refresh() }
            .toolbar { Button("Refresh", systemImage: "arrow.clockwise") { Task { await refresh() } }.help("Refresh device information") }
    }
    private func refresh() async {
        do { devices = try await service.devices(); error = nil }
        catch { self.error = error.localizedDescription }
    }
}
