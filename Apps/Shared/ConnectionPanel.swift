import SwiftUI
import Caliper3DTransfer
#if os(iOS)
import UIKit
#endif

struct ConnectionPanel: View {
    let model: ConnectionCoordinator
    @State private var forgetting: TrustedPeer?
    @Environment(\.openURL) private var openURL
    var body: some View {
        Form {
            Section("Connection") {
                Text(model.state.message)
                if let name = model.peerName { LabeledContent("Device", value: name) }
                switch model.state {
                case .verification(let code), .waitingForConfirmation(let code):
                    Text(code).font(.largeTitle.monospacedDigit()).textSelection(.enabled)
                        .accessibilityLabel("Verification code \(code)")
                    Text("Confirm only if this code matches the code shown on your other device.")
                    if case .verification = model.state {
                        Button("Confirm Matching Code") { Task { await model.confirm() } }.buttonStyle(.borderedProminent)
                    }
                    Button("Reject", role: .destructive) { Task { await model.reject() } }
                case .connected(let peer):
                    LabeledContent("System", value: peer.operatingSystem)
                    if let supported = peer.objectCaptureSupported { LabeledContent("Object Capture", value: supported ? "Supported" : "Not supported") }
                    Button("Disconnect") { Task { await model.disconnect() } }
                case .connecting, .exchangingIdentity, .awaitingCode:
                    ProgressView(); Button("Cancel") { Task { await model.disconnect() } }
                case .savingTrust: ProgressView()
                default: EmptyView()
                }
            }
            if model.role == .mac {
                Section("Pair an iPhone") {
                    if model.pairingWindowOpen {
                        Text("Open Caliper3D Capture → Connect to Mac → Pair. This pairing window closes after two minutes.")
                        Button("Close Pairing Window") { Task { await model.closePairingWindow() } }
                    } else {
                        Button("Pair iPhone") { Task { await model.allowPairing() } }
                        Text("Pairing requires matching codes and confirmation on both devices.").foregroundStyle(.secondary)
                    }
                }
            } else {
                Section("Available Macs") {
                    if model.macs.isEmpty { Text("Keep Caliper3D open on your Mac and connect both devices to the same local network.").foregroundStyle(.secondary) }
                    ForEach(model.macs) { mac in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(mac.name).font(.headline)
                            if model.trustedPeers.isEmpty {
                                Button("Pair") { Task { await model.connect(macID: mac.id) } }
                            } else {
                                Menu("Connect") {
                                    ForEach(model.trustedPeers) { peer in
                                        Button("Connect to paired \(peer.name)") { Task { await model.connect(macID: mac.id, expectedFingerprint: peer.fingerprint) } }
                                    }
                                    Button("Pair as a New Mac") { Task { await model.connect(macID: mac.id) } }
                                }
                            }
                        }
                    }
                    Text("For a new pairing, choose Pair iPhone in the Mac’s Devices screen first.").font(.caption)
                }
            }
            Section("Paired Devices") {
                if model.trustedPeers.isEmpty { Text("No paired devices").foregroundStyle(.secondary) }
                ForEach(model.trustedPeers) { peer in
                    HStack {
                        Text(peer.name); Spacer()
                        Button("Forget", role: .destructive) { forgetting = peer }
                    }
                }
            }
            Section("Local Network") {
                switch model.discovery {
                case .stopped: Text("Stopped")
                case .preparing: ProgressView("Preparing local network…")
                case .ready: Text(model.role == .mac ? "Caliper3D is available on this network" : "Searching for Macs")
                case .failed(let reason): Text(reason)
                }
                Button("Retry Network") { Task { await model.stop(); await model.start() } }
                #if os(iOS)
                Button("Open Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) } }
                #endif
            }
        }
        .confirmationDialog("Forget this device?", isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }), titleVisibility: .visible) {
            if let peer = forgetting { Button("Forget \(peer.name)", role: .destructive) { forgetting = nil; Task { await model.forget(peer.fingerprint) } } }
        } message: { Text("The device will need explicit pairing again. Saved captures are unchanged.") }
        .navigationTitle(model.role == .mac ? "Devices" : "Connect to Mac")
        .task { await model.start() }
    }
}
