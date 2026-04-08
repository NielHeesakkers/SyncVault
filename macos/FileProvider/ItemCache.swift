import Foundation
import SQLite
import os.log

/// Local SQLite cache for FileProvider items.
/// All enumeration reads from this cache (fast, offline-capable).
/// Background refresh keeps it in sync with the server.
actor ItemCache {
    private let db: Connection
    private let logger = Logger(subsystem: "com.syncvault.fileprovider", category: "ItemCache")

    // Table
    private let items = Table("items")
    private let colID = SQLite.Expression<String>("id")
    private let colParentID = SQLite.Expression<String?>("parent_id")
    private let colName = SQLite.Expression<String>("name")
    private let colIsDir = SQLite.Expression<Bool>("is_dir")
    private let colSize = SQLite.Expression<Int64>("size")
    private let colContentHash = SQLite.Expression<String?>("content_hash")
    private let colMimeType = SQLite.Expression<String?>("mime_type")
    private let colCreatedAt = SQLite.Expression<String?>("created_at")
    private let colUpdatedAt = SQLite.Expression<String?>("updated_at")
    private let colDeletedAt = SQLite.Expression<String?>("deleted_at")
    private let colIsDownloaded = SQLite.Expression<Bool>("is_downloaded")
    private let colRank = SQLite.Expression<Int64>("rank")

    init() throws {
        let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "DE59N86W33.com.syncvault.shared")
        let dbPath: String
        if let url = groupURL {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            dbPath = url.appendingPathComponent("fileprovider_cache.sqlite3").path
        } else {
            dbPath = NSTemporaryDirectory() + "/fileprovider_cache.sqlite3"
        }

        db = try Connection(dbPath)
        try db.execute("PRAGMA journal_mode = WAL")
        try createTable()
        logger.info("ItemCache opened at \(dbPath, privacy: .public)")
    }

    private func createTable() throws {
        try db.run(items.create(ifNotExists: true) { t in
            t.column(colID, primaryKey: true)
            t.column(colParentID)
            t.column(colName)
            t.column(colIsDir, defaultValue: false)
            t.column(colSize, defaultValue: 0)
            t.column(colContentHash)
            t.column(colMimeType)
            t.column(colCreatedAt)
            t.column(colUpdatedAt)
            t.column(colDeletedAt)
            t.column(colIsDownloaded, defaultValue: false)
            t.column(colRank, defaultValue: 0)
        })
        try db.run(items.createIndex(colParentID, ifNotExists: true))
        try db.run(items.createIndex(colRank, ifNotExists: true))
    }

    // MARK: - Rank

    private func nextRank() -> Int64 {
        let maxRank = (try? db.scalar(items.select(colRank.max))) ?? 0
        return (maxRank ?? 0) + 1
    }

    func currentRank() -> Int64 {
        return (try? db.scalar(items.select(colRank.max))) ?? 0 ?? 0
    }

    // MARK: - Upsert

    func upsert(_ file: FPServerFile, downloaded: Bool = false) {
        let rank = nextRank()
        let insert = items.upsert(
            colID <- file.id,
            colParentID <- file.parentID,
            colName <- file.name,
            colIsDir <- file.isDir,
            colSize <- file.size,
            colContentHash <- file.contentHash,
            colMimeType <- file.mimeType,
            colCreatedAt <- file.createdAt,
            colUpdatedAt <- file.updatedAt,
            colDeletedAt <- file.deletedAt,
            colIsDownloaded <- downloaded,
            colRank <- rank,
            onConflictOf: colID
        )
        try? db.run(insert)
    }

    // MARK: - Query

    func listChildren(parentID: String) -> [CachedItem] {
        let query = items
            .filter(colParentID == parentID)
            .filter(colDeletedAt == nil)
            .order(colIsDir.desc, colName.asc)
        return queryItems(query)
    }

    func getItem(_ id: String) -> CachedItem? {
        let query = items.filter(colID == id)
        return queryItems(query).first
    }

    func allItems() -> [CachedItem] {
        let query = items.filter(colDeletedAt == nil).order(colName.asc)
        return queryItems(query)
    }

    func getChanges(sinceRank: Int64) -> (updated: [CachedItem], deleted: [String]) {
        var updated: [CachedItem] = []
        var deleted: [String] = []

        let query = items.filter(colRank > sinceRank).order(colRank.asc)
        guard let rows = try? db.prepare(query) else { return (updated, deleted) }

        for row in rows {
            if row[colDeletedAt] != nil {
                deleted.append(row[colID])
            } else {
                updated.append(rowToCachedItem(row))
            }
        }
        return (updated, deleted)
    }

    // MARK: - State updates

    func markDownloaded(_ id: String) {
        let item = items.filter(colID == id)
        try? db.run(item.update(colIsDownloaded <- true, colRank <- nextRank()))
    }

    func markDeleted(_ id: String) {
        let item = items.filter(colID == id)
        let now = ISO8601DateFormatter().string(from: Date())
        try? db.run(item.update(colDeletedAt <- now, colRank <- nextRank()))
    }

    func clearAll() {
        try? db.run(items.delete())
        logger.info("ItemCache cleared")
    }

    // MARK: - Helpers

    private func queryItems(_ query: Table) -> [CachedItem] {
        guard let rows = try? db.prepare(query) else { return [] }
        return rows.map { rowToCachedItem($0) }
    }

    private func rowToCachedItem(_ row: Row) -> CachedItem {
        CachedItem(
            id: row[colID],
            parentID: row[colParentID],
            name: row[colName],
            isDir: row[colIsDir],
            size: row[colSize],
            contentHash: row[colContentHash],
            mimeType: row[colMimeType],
            createdAt: row[colCreatedAt],
            updatedAt: row[colUpdatedAt],
            deletedAt: row[colDeletedAt],
            isDownloaded: row[colIsDownloaded],
            rank: row[colRank]
        )
    }
}

// MARK: - CachedItem

struct CachedItem {
    let id: String
    let parentID: String?
    let name: String
    let isDir: Bool
    let size: Int64
    let contentHash: String?
    let mimeType: String?
    let createdAt: String?
    let updatedAt: String?
    let deletedAt: String?
    let isDownloaded: Bool
    let rank: Int64

    func toServerFile() -> FPServerFile {
        FPServerFile(
            id: id,
            parentID: parentID,
            name: name,
            isDir: isDir,
            size: size,
            contentHash: contentHash,
            mimeType: mimeType,
            createdAt: createdAt,
            updatedAt: updatedAt,
            deletedAt: deletedAt,
            removedLocally: nil
        )
    }
}
