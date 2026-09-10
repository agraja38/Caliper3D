import Foundation
import ModelIO
import Caliper3DCore

/// Output must be a new derived file under processed/, never an original capture/reconstruction.
public protocol MeshProcessingService: Sendable {
    func smooth(input: URL, output: URL) async throws
}
public protocol MeshAnalysisService: Sendable {
    func analyze(_ input: URL) async throws -> MeshStatistics
}
public protocol ExportService: Sendable {
    func exportSTL(input: URL, destination: URL, units: LengthUnit) async throws
}
