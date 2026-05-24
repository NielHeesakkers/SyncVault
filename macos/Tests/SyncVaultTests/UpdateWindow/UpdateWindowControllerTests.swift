import XCTest
@testable import SyncVault

@MainActor
final class UpdateWindowControllerTests: XCTestCase {
    func testInitialStateIsAvailable() {
        let c = UpdateWindowController(version: "3.2.0", changelog: ["a"], sizeBytes: 3_000_000)
        XCTAssertEqual(c.state, .available)
    }

    func testInstallTriggersDownloading() {
        let c = UpdateWindowController(version: "3.2.0", changelog: [], sizeBytes: 0)
        c.install()
        if case .downloading(let p) = c.state { XCTAssertEqual(p, 0) }
        else { XCTFail("Expected .downloading, got \(c.state)") }
    }

    func testProgressUpdatesClamp() {
        let c = UpdateWindowController(version: "3.2.0", changelog: [], sizeBytes: 0)
        c.install()
        c.updateProgress(0.5)
        if case .downloading(let p) = c.state { XCTAssertEqual(p, 0.5) }
        else { XCTFail() }
        c.updateProgress(1.5)  // clamps to 1.0
        if case .downloading(let p) = c.state { XCTAssertEqual(p, 1.0) }
        else { XCTFail() }
        c.updateProgress(-0.2) // clamps to 0.0
        if case .downloading(let p) = c.state { XCTAssertEqual(p, 0.0) }
        else { XCTFail() }
    }

    func testProgressUpdateIgnoredOutsideDownloading() {
        let c = UpdateWindowController(version: "3.2.0", changelog: [], sizeBytes: 0)
        // state == .available
        c.updateProgress(0.5)
        XCTAssertEqual(c.state, .available)
    }

    func testDownloadCompletePromotesToReady() {
        let c = UpdateWindowController(version: "3.2.0", changelog: [], sizeBytes: 0)
        c.install()
        let dmg = URL(fileURLWithPath: "/tmp/test.dmg")
        c.downloadCompleted(at: dmg)
        XCTAssertEqual(c.state, .ready(dmg: dmg))
    }

    func testFailedSetsErrorState() {
        let c = UpdateWindowController(version: "3.2.0", changelog: [], sizeBytes: 0)
        c.failed("Network unreachable")
        if case .error(let msg) = c.state { XCTAssertEqual(msg, "Network unreachable") }
        else { XCTFail() }
    }
}
