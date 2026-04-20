import Foundation
import SQLite

struct SyncFileState {
    let taskID: String
    let relativePath: String
    let contentHash: String
    let isDir: Bool
    let syncedAt: Date
    let fileSize: Int64
    let modTime: Double  // Unix timestamp (seconds since 1970)
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
    private let colFileSize = SQLite.Expression<Int64>("file_size")
    private let colModTime = SQLite.Expression<Double>("mod_time")

    // Pending changes queue (crash-safe FSEvents)
    private let pendingChanges = Table("pending_changes")
    private let colPendingID = SQLite.Expression<Int64>("id")
    private let colPendingTaskID = SQLite.Expression<String>("task_id")
    private let colPendingPath = SQLite.Expression<String>("path")
    private let colPendingDetectedAt = SQLite.Expression<Double>("detected_at")

    // Per-file retry tracking (one bad file shouldn't poison the whole cycle)
    private let fileRetries = Table("file_retries")
    private let colRetryTaskID = SQLite.Expression<String>("task_id")
    private let colRetryRelPath = SQLite.Expression<String>("relative_path")
    private let colRetryCount = SQLite.Expression<Int>("retry_count")
    private let colRetryLastError = SQLite.Expression<String>("last_error")
    private let colRetryLastAttempt = SQLite.Expression<Double>("last_attempt_at")

    init(path: String) throws {
        db = try Connection(path)
        try createTables()
        try migrateSchema()
    }

    private func createTables() throws {
        try db.run(syncStates.create(ifNotExists: true) { t in
            t.column(colTaskID)
            t.column(colRelativePath)
            t.column(colContentHash, defaultValue: "")
            t.column(colIsDir, defaultValue: false)
            t.column(colSyncedAt)
            t.column(colFileSize, defaultValue: 0)
            t.column(colModTime, defaultValue: 0)
            t.primaryKey(colTaskID, colRelativePath)
        })

        // Pending changes table — FSEvents persisted here so they survive app crashes.
        try db.run(pendingChanges.create(ifNotExists: true) { t in
            t.column(colPendingID, primaryKey: .autoincrement)
            t.column(colPendingTaskID)
            t.column(colPendingPath)
            t.column(colPendingDetectedAt)
            t.unique(colPendingTaskID, colPendingPath)
        })
        try db.run("CREATE INDEX IF NOT EXISTS idx_pending_task ON pending_changes(task_id)")

        // File retry tracking — per-file failure state with exponential backoff.
        try db.run(fileRetries.create(ifNotExists: true) { t in
            t.column(colRetryTaskID)
            t.column(colRetryRelPath)
            t.column(colRetryCount, defaultValue: 0)
            t.column(colRetryLastError, defaultValue: "")
            t.column(colRetryLastAttempt, defaultValue: 0)
            t.primaryKey(colRetryTaskID, colRetryRelPath)
        })
    }

    /// Add file_size and mod_time columns if they don't exist (migration for existing databases)
    private func migrateSchema() throws {
        // Try adding columns — ignore error if they already exist
        _ = try? db.run(syncStates.addColumn(colFileSize, defaultValue: 0))
        _ = try? db.run(syncStates.addColumn(colModTime, defaultValue: 0))
    }

    // MARK: - Pending Changes Queue

    /// Enqueue an FSEvents-detected change. Idempotent on (task_id, path).
    func enqueueChange(taskID: String, path: String) {
        let now = Date().timeIntervalSince1970
        // INSERT OR IGNORE semantics via the unique constraint
        _ = try? db.run(pendingChanges.insert(or: .ignore,
            colPendingTaskID <- taskID,
            colPendingPath <- path,
            colPendingDetectedAt <- now
        ))
    }

    /// Drain all pending changes for a task — returns paths and deletes them atomically.
    /// If the sync fails partway through, the changes are already consumed (by design:
    /// the next full scan will catch anything still out-of-sync).
    func drainChanges(taskID: String) throws -> Set<String> {
        var paths: Set<String> = []
        try db.transaction {
            for row in try db.prepare(pendingChanges.filter(colPendingTaskID == taskID)) {
                paths.insert(row[colPendingPath])
            }
            try db.run(pendingChanges.filter(colPendingTaskID == taskID).delete())
        }
        return paths
    }

    /// Count of pending changes across all tasks — used to trigger crash-recovery sync on startup.
    func pendingChangeCount() -> Int {
        (try? db.scalar(pendingChanges.count)) ?? 0
    }

    /// Count of pending changes for a specific task.
    func pendingChangeCount(taskID: String) -> Int {
        (try? db.scalar(pendingChanges.filter(colPendingTaskID == taskID).count)) ?? 0
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
                syncedAt: row[colSyncedAt],
                fileSize: row[colFileSize],
                modTime: row[colModTime]
            )
            states[state.relativePath] = state
        }
        return states
    }

    /// Quick check: has this file changed since last sync? Uses mtime+size to avoid hashing.
    /// Returns the cached hash if unchanged, nil if the file needs re-hashing.
    func cachedHashIfUnchanged(taskID: String, relativePath: String, currentSize: Int64, currentModTime: Double) -> String? {
        guard let row = try? db.pluck(syncStates.filter(
            colTaskID == taskID && colRelativePath == relativePath
        )) else { return nil }

        let storedSize = row[colFileSize]
        let storedMtime = row[colModTime]
        let storedHash = row[colContentHash]

        // If mtime and size match, file hasn't changed — return cached hash
        if storedSize == currentSize && abs(storedMtime - currentModTime) < 0.001 && !storedHash.isEmpty {
            return storedHash
        }
        return nil
    }

    // MARK: - Update

    /// Record that a file/directory was synced (with mtime+size for fast change detection)
    func updateState(taskID: String, relativePath: String, contentHash: String, isDir: Bool, fileSize: Int64 = 0, modTime: Double = 0) throws {
        try db.run(syncStates.insert(or: .replace,
            colTaskID <- taskID,
            colRelativePath <- relativePath,
            colContentHash <- contentHash,
            colIsDir <- isDir,
            colSyncedAt <- Date(),
            colFileSize <- fileSize,
            colModTime <- modTime
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
    func replaceAllStates(taskID: String, files: [(relativePath: String, contentHash: String, isDir: Bool, fileSize: Int64, modTime: Double)]) throws {
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
                    colSyncedAt <- now,
                    colFileSize <- file.fileSize,
                    colModTime <- file.modTime
                ))
            }
        }
    }

    // MARK: - Per-file Retry Tracking

    /// Max retry attempts before a file is considered permanently failed and skipped.
    static let maxRetries = 3

    /// Record that a file failed to sync. Increments retry_count and stores the last error.
    func markFileFailed(taskID: String, relativePath: String, error: String) {
        let now = Date().timeIntervalSince1970
        let existing = (try? db.pluck(fileRetries.filter(
            colRetryTaskID == taskID && colRetryRelPath == relativePath
        )))
        let count = (existing?[colRetryCount] ?? 0) + 1
        _ = try? db.run(fileRetries.insert(or: .replace,
            colRetryTaskID <- taskID,
            colRetryRelPath <- relativePath,
            colRetryCount <- count,
            colRetryLastError <- String(error.prefix(500)), // cap error message length
            colRetryLastAttempt <- now
        ))
    }

    /// Clear retry state for a file (called after a successful sync).
    func clearFileFailure(taskID: String, relativePath: String) {
        _ = try? db.run(fileRetries.filter(
            colRetryTaskID == taskID && colRetryRelPath == relativePath
        ).delete())
    }

    /// Should we attempt this file in the current sync cycle?
    /// Returns false if retry_count >= max AND last_attempt was recent (exponential backoff:
    /// 1m, 5m, 15m, 1h, then permanent until manual intervention).
    func shouldAttemptFile(taskID: String, relativePath: String) -> Bool {
        guard let row = try? db.pluck(fileRetries.filter(
            colRetryTaskID == taskID && colRetryRelPath == relativePath
        )) else {
            return true // no failure history
        }
        let count = row[colRetryCount]
        if count < Self.maxRetries { return true }
        // Permanently failed — only re-attempt after 1 hour to allow recovery scenarios
        let lastAttempt = row[colRetryLastAttempt]
        let now = Date().timeIntervalSince1970
        return (now - lastAttempt) > 3600
    }

    /// Count of permanently-failed files for diagnostics / UI.
    func permanentlyFailedCount(taskID: String) -> Int {
        (try? db.scalar(
            fileRetries.filter(colRetryTaskID == taskID && colRetryCount >= Self.maxRetries).count
        )) ?? 0
    }

    // MARK: - Legacy compatibility

    func updateState(taskID: String, fileName: String, contentHash: String) throws {
        try updateState(taskID: taskID, relativePath: fileName, contentHash: contentHash, isDir: false)
    }

    func removeState(taskID: String, fileName: String) throws {
        try removeState(taskID: taskID, relativePath: fileName)
    }
}
