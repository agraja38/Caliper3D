import XCTest
import Caliper3DCore
@testable import Caliper3DTransfer

final class TransferTests: XCTestCase {
    func testSafePaths() {
        XCTAssertTrue(TransferPolicy.isSafeRelativePath("capture/00001.heic"))
        for path in ["", "/etc/passwd", "../x", "capture/../x", "a//b", "a/./b", "a\\b", "a:", "a\0b"] {
            XCTAssertFalse(TransferPolicy.isSafeRelativePath(path), path)
        }
    }
    func testSHA256KnownVector() {
        XCTAssertEqual(TransferPolicy.digest(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
    func testDiscoveryIsStableAndExplicitlyDemo() async throws {
        let service = DemoDiscoveryService()
        let first = try await service.devices(); let second = try await service.devices()
        XCTAssertEqual(first, second); XCTAssertTrue(try XCTUnwrap(first.first).isDemo)
        let real = try await UnavailableDiscoveryService().devices(); XCTAssertTrue(real.isEmpty)
    }
    func testDemoTransferReceipt() async throws {
        let capture = CaptureRecord(name: "Demo", imageCount: 48, isDemo: true)
        let receipt = try await DemoTransferService().send(capture)
        XCTAssertEqual(receipt.captureID, capture.id); XCTAssertTrue(receipt.isDemo)
    }
    func testDemoCannotSendRealCapture() async {
        do { _ = try await DemoTransferService().send(CaptureRecord(name: "Real", imageCount: 1, isDemo: false)); XCTFail() } catch { }
    }
    func testTransferCancellation() async {
        let task = Task { try await DemoTransferService().send(CaptureRecord(name: "Demo", imageCount: 48, isDemo: true)) }
        task.cancel()
        do { _ = try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
    }
}
