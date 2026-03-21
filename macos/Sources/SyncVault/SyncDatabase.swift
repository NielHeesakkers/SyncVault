import Foundation
import SQLite

struct SyncFileState {
    let taskID: String
    let fileName: String
    let contentHash: String
    let syncedAt: Date
}

class SyncDatabase {
    private let db: Connection

    // Tables
    private let syncStates = Table("sync_states")
    private let colTaskID = SQLite.Expression<String>("task_id")
    private let colFileName = SQLite.Expression<String>("file_name")
    private let colContentHash = SQLite.Expression<String>("content_hash")
    private let colSyncedAt = SQLite.Expression<Date>("synced_at")

    init(path: String) throws {
        db = try Connection(path)
        try createTables()
    }

    private func createTables() throws {
        try db.run(syncStates.create(ifNotExists: true) { t in
            t.column(colTaskID)
            t.column(colFileName)
            t.column(colContentHash)
            t.column(colSyncedAt)
            t.primaryKey(colTaskID, colFileName)
        })
    }

    func getStates(taskID: String) throws -> [String: SyncFileState] {
        var states: [String: SyncFileState] = [:]
        for row in try db.prepare(syncStates.filter(colTaskID == taskID)) {
            let state = SyncFileState(
                taskID: row[colTaskID],
                fileName: row[colFileName],
                contentHash: row[colContentHash],
                syncedAt: row[colSyncedAt]
            )
            states[state.fileName] = state
        }
        return states
    }

    func updateState(taskID: String, fileName: String, contentHash: String) throws {
        try db.run(syncStates.insert(or: .replace,
            colTaskID <- taskID,
            colFileName <- fileName,
            colContentHash <- contentHash,
            colSyncedAt <- Date()
        ))
    }

    func removeState(taskID: String, fileName: String) throws {
        try db.run(syncStates.filter(colTaskID == taskID && colFileName == fileName).delete())
    }
}
