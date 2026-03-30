import Foundation
import SQLite

struct SyncFileState {
    let taskID: String
    let relativePath: String
    let contentHash: String
    let isDir: Bool
    let syncedAt: Date
}

class SyncDatabase {
    private let db: Connection

    // Tables
    private let syncStates = Table("sync_states_v2")
    private let colTaskID = SQLite.Expression<String>("task_id")
    private let colRelativePath = SQLite.Expression<String>("relative_path")
    private let colContentHash = SQLite.Expression<String>("content_hash")
    private let colIsDir = SQLite.Expression<Bool>("is_dir")
    private let colSyncedAt = SQLite.Expression<Date>("synced_at")

    init(path: String) throws {
        db = try Connection(path)
        try createTables()
    }

    private func createTables() throws {
        try db.run(syncStates.create(ifNotExists: true) { t in
            t.column(colTaskID)
            t.column(colRelativePath)
            t.column(colContentHash, defaultValue: "")
            t.column(colIsDir, defaultValue: false)
            t.column(colSyncedAt)
            t.primaryKey(colTaskID, colRelativePath)
        })
    }

    // MARK: - Query

    /// Get all known states for a task — the "journal" of what was synced last time
    func getStates(taskID: String) throws -> [String: SyncFileState] {
        var states: [String: SyncFileState] = [:]
        for row in try db.prepare(syncStates.filter(colTaskID == taskID)) {
            let state = SyncFileState(
                taskID: row[colTaskID],
                relativePath: row[colRelativePath],
                contentHash: row[colContentHash],
                isDir: row[colIsDir],
                syncedAt: row[colSyncedAt]
            )
            states[state.relativePath] = state
        }
        return states
    }

    // MARK: - Update

    /// Record that a file/directory was synced
    func updateState(taskID: String, relativePath: String, contentHash: String, isDir: Bool) throws {
        try db.run(syncStates.insert(or: .replace,
            colTaskID <- taskID,
            colRelativePath <- relativePath,
            colContentHash <- contentHash,
            colIsDir <- isDir,
            colSyncedAt <- Date()
        ))
    }

    /// Remove a file from the journal (it was deleted)
    func removeState(taskID: String, relativePath: String) throws {
        try db.run(syncStates.filter(colTaskID == taskID && colRelativePath == relativePath).delete())
    }

    /// Remove all states for paths that start with a prefix (directory deleted)
    func removeStatesUnder(taskID: String, pathPrefix: String) throws {
        let prefix = pathPrefix.hasSuffix("/") ? pathPrefix : pathPrefix + "/"
        try db.run(syncStates.filter(
            colTaskID == taskID && (colRelativePath == pathPrefix || colRelativePath.like("\(prefix)%"))
        ).delete())
    }

    /// Replace the entire journal for a task with the current state
    /// Called after a successful full sync
    func replaceAllStates(taskID: String, files: [(relativePath: String, contentHash: String, isDir: Bool)]) throws {
        try db.transaction {
            // Clear old states
            try db.run(syncStates.filter(colTaskID == taskID).delete())
            // Insert new states
            let now = Date()
            for file in files {
                try db.run(syncStates.insert(
                    colTaskID <- taskID,
                    colRelativePath <- file.relativePath,
                    colContentHash <- file.contentHash,
                    colIsDir <- file.isDir,
                    colSyncedAt <- now
                ))
            }
        }
    }

    // MARK: - Legacy compatibility

    func updateState(taskID: String, fileName: String, contentHash: String) throws {
        try updateState(taskID: taskID, relativePath: fileName, contentHash: contentHash, isDir: false)
    }

    func removeState(taskID: String, fileName: String) throws {
        try removeState(taskID: taskID, relativePath: fileName)
    }
}
