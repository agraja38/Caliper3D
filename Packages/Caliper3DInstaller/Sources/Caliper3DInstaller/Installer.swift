import Foundation

public enum InstallationStatus: String, Equatable, Sendable { case unknown, installed, notInstalled }
public protocol CompanionInstallerService: Sendable {
    func status(deviceID: UUID) async throws -> InstallationStatus
}
/// Read-only boundary. Installation requires a separately reviewed Xcode/provisioning design.
public struct UnavailableCompanionInstallerService: CompanionInstallerService {
    public init() {}
    public func status(deviceID: UUID) async throws -> InstallationStatus { .unknown }
}
