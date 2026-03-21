import XCTest
@testable import SyncVault

final class SyncVaultTests: XCTestCase {
    func testSyncTaskInit() {
        let task = SyncTask(
            localPath: "/tmp/test",
            remoteFolderID: "folder-123",
            remoteFolderName: "Test Folder"
        )
        XCTAssertEqual(task.localPath, "/tmp/test")
        XCTAssertEqual(task.remoteFolderID, "folder-123")
        XCTAssertEqual(task.mode, .twoWay)
        XCTAssertTrue(task.isEnabled)
        XCTAssertEqual(task.intervalSeconds, 30)
        XCTAssertEqual(task.excludePatterns, [".DS_Store", "*.tmp", "Thumbs.db"])
    }

    func testAppConfigCodable() throws {
        let task = SyncTask(localPath: "/tmp", remoteFolderID: "id1", remoteFolderName: "Folder")
        let config = AppConfig(serverURL: "https://example.com", username: "user", syncTasks: [task])
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        XCTAssertEqual(decoded.serverURL, "https://example.com")
        XCTAssertEqual(decoded.username, "user")
        XCTAssertEqual(decoded.syncTasks.count, 1)
    }

    func testConflictName() {
        let name = SyncEngine.conflictName(for: "document.txt")
        XCTAssertTrue(name.hasSuffix(".txt"))
        XCTAssertTrue(name.hasPrefix("document_"))
    }
}
