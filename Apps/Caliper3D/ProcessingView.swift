import SwiftUI
import Caliper3DCore

@MainActor @Observable
final class ProcessingModel {
    struct Job: Identifiable {
        let id: UUID
        let name: String
        var state: String
    }
    var jobs: [Job] = []
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private let service: any PhotogrammetryService
    init(service: any PhotogrammetryService) { self.service = service }
    func start(_ project: ScanProject) {
        guard project.manifest.captureMethod == .demo, tasks[project.id] == nil else { return }
        jobs.removeAll { $0.id == project.id }
        jobs.insert(Job(id: project.id, name: project.manifest.name, state: "Simulating reconstruction…"), at: 0)
        tasks[project.id] = Task {
            do {
                _ = try await service.reconstruct(project)
                update(project.id, "Demo complete · synthetic geometry, no model file created")
            } catch is CancellationError { update(project.id, "Cancelled") }
            catch { update(project.id, "Failed: " + error.localizedDescription) }
            tasks[project.id] = nil
        }
    }
    func isRunning(_ id: UUID) -> Bool { tasks[id] != nil }
    func cancel(_ id: UUID) { tasks[id]?.cancel() }
    private func update(_ id: UUID, _ state: String) {
        if let index = jobs.firstIndex(where: { $0.id == id }) { jobs[index].state = state }
    }
}
struct ProcessingView: View {
    let model: ProcessingModel
    var body: some View {
        Group {
            if model.jobs.isEmpty {
                ContentUnavailableView("No processing jobs", systemImage: "gearshape.2", description: Text("Open a demo project to simulate reconstruction. Photo reconstruction is coming in a later milestone."))
            } else {
                List(model.jobs) { job in
                    HStack {
                        VStack(alignment: .leading, spacing: 6) { Text(job.name); Text(job.state).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        if model.isRunning(job.id) {
                            ProgressView().controlSize(.small)
                            Button("Cancel") { model.cancel(job.id) }
                        }
                    }.padding(.vertical, 6)
                }
            }
        }.navigationTitle("Processing")
    }
}
