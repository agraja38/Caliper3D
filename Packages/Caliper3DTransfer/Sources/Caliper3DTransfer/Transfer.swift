import Foundation
import Network
import CryptoKit
import Caliper3DCore

public struct DiscoveredDevice: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let operatingSystem: String
    public let hasLiDAR: Bool?
    public let isDemo: Bool
    public init(id: UUID = UUID(), name: String, operatingSystem: String, hasLiDAR: Bool?, isDemo: Bool) {
        self.id = id; self.name = name; self.operatingSystem = operatingSystem
        self.hasLiDAR = hasLiDAR; self.isDemo = isDemo
    }
}
public protocol DeviceDiscoveryService: Sendable { func devices() async throws -> [DiscoveredDevice] }
public protocol ScanTransferService: Sendable { func send(_ capture: CaptureRecord) async throws -> TransferReceipt }
public struct TransferReceipt: Equatable, Sendable {
    public let captureID: UUID
    public let isDemo: Bool
    public init(captureID: UUID, isDemo: Bool) { self.captureID = captureID; self.isDemo = isDemo }
}
public enum TransferPolicy {
    public static let bonjourType = "_caliper3d._tcp"
    public static let maximumFileBytes: Int64 = 100_000_000
    public static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    public static func isSafeRelativePath(_ path: String) -> Bool {
        let pieces = path.split(separator: "/", omittingEmptySubsequences: false)
        return !path.isEmpty && !path.contains("\\") && !path.contains(":") && !path.contains("\0")
            && pieces.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}
/// No listener is started until authenticated pairing is implemented.
public struct UnavailableDiscoveryService: DeviceDiscoveryService {
    public init() {}
    public func devices() async throws -> [DiscoveredDevice] { [] }
}
public struct DemoDiscoveryService: DeviceDiscoveryService {
    private let device = DiscoveredDevice(name: "Demo iPhone", operatingSystem: "iOS 17+ (simulated)", hasLiDAR: true, isDemo: true)
    public init() {}
    public func devices() async throws -> [DiscoveredDevice] { [device] }
}
public struct DemoTransferService: ScanTransferService {
    public init() {}
    public func send(_ capture: CaptureRecord) async throws -> TransferReceipt {
        guard capture.isDemo else { throw ServiceError.notImplemented("Real transfer") }
        try await Task.sleep(for: .seconds(1))
        return TransferReceipt(captureID: capture.id, isDemo: true)
    }
}
public struct UnavailableTransferService: ScanTransferService {
    public init() {}
    public func send(_ capture: CaptureRecord) async throws -> TransferReceipt { throw ServiceError.notImplemented("Local transfer") }
}
