import SwiftUI
import Caliper3DCore
import Caliper3DTransfer

@MainActor @Observable
final class CaptureFlowModel {
    enum Stage: Equatable { case ready, checking, capturing, review, sending, sent, unavailable(String), failed(String) }
    var stage: Stage = .ready
    var recent: [CaptureRecord] = []
    var current: CaptureRecord?
    private let captureService: any CaptureService
    private let transferService: any ScanTransferService
    private var operation: Task<Void, Never>?
    init(capture: any CaptureService, transfer: any ScanTransferService) {
        captureService = capture; transferService = transfer
    }
    func begin() {
        operation?.cancel(); current = nil; stage = .checking
        operation = Task {
            let compatibility = await captureService.compatibility()
            guard !Task.isCancelled else { return }
            guard compatibility == .available else {
                if case .unavailable(let message) = compatibility { stage = .unavailable(message) }
                return
            }
            stage = .capturing
            do {
                let record = try await captureService.capture()
                try Task.checkCancellation()
                current = record; recent.insert(record, at: 0); stage = .review
            } catch is CancellationError { }
            catch { stage = .failed(error.localizedDescription) }
        }
    }
    func review(_ record: CaptureRecord) { current = record; stage = .review }
    func send() {
        guard let current, stage == .review else { return }
        stage = .sending
        operation = Task {
            do {
                _ = try await transferService.send(current)
                try Task.checkCancellation(); stage = .sent
            } catch is CancellationError { }
            catch { stage = .failed(error.localizedDescription) }
        }
    }
    func cancel() { operation?.cancel(); operation = nil; stage = .ready }
}
