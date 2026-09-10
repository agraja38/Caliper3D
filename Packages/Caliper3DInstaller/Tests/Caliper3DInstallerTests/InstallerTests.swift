import XCTest
@testable import Caliper3DInstaller
final class InstallerTests: XCTestCase {
    func testDoesNotInventInstallationStatus() async throws {
        let status = try await UnavailableCompanionInstallerService().status(deviceID: UUID())
        XCTAssertEqual(status, .unknown)
    }
}
