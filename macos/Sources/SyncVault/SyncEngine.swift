import Foundation
import CryptoKit
import os

private let logger = Logger(subsystem: "com.syncvault.app", category: "SyncEngine")

actor SyncEngine {
    private let apiClient: APIClient
    private let db: SyncDatabase
    private var isRunning = false

    init(apiClient: APIClient, dbPath: URL) throws {
        self.apiClient = apiClient
        self.db = try SyncDatabase(path: dbPath.path)
    }

    func syncTask(_ task: SyncTask, onProgress: @Sendable @escaping (SyncProgress) -> Void = { _ in }) async throws -> SyncResult {
        guard !isRunning else { return SyncResult(uploaded: 0, downloaded: 0, deleted: 0, conflicts: 0, errors: 0, fileActivity: []) }
        isRunning = true
        defer { isRunning = false }

        var result = SyncResult(uploaded: 0, downloaded: 0, deleted: 0, conflicts: 0, errors: 0, fileActivity: [])
        let taskID = task.id.uuidString
        let basePath = task.localPath

        // 1. Scan local files
        let localFiles = scanLocalFiles(at: basePath, excludePatterns: task.excludePatterns)
        logger.info("Local files: \(localFiles.count) (path: \(basePath))")

        // 2. Get remote files
        let remoteFiles = try await apiClient.listFiles(parentID: task.remoteFolderID)
        logger.info(" Remote files: \(remoteFiles.count) (folderID: \(task.remoteFolderID))")
        for f in remoteFiles.prefix(10) {
            logger.info("   remote: \(f.name) (dir=\(f.isDir), hash=\(f.contentHash ?? "nil"))")
        }

        // 3. Get known state from sync database
        let knownState = try db.getStates(taskID: taskID)
        logger.info(" Known state: \(knownState.count) entries")

        // 4. Determine actions
        let actions = determineActions(
            local: localFiles,
            remote: remoteFiles,
            known: knownState,
            mode: task.mode,
            basePath: basePath
        )
        logger.info(" Actions: \(actions.count)")
        for a in actions.prefix(10) {
            logger.info("   action: \(a)")
        }

        // 5. Execute actions with progress
        let totalActions = actions.count
        var completed = 0
        var totalBytesTransferred: Int64 = 0
        let syncStart = Date()

        for action in actions {
            do {
                let startTime = Date()

                switch action {
                case .upload(let path, let remoteName):
                    let data = try Data(contentsOf: URL(fileURLWithPath: path))
                    let size = Int64(data.count)

                    onProgress(SyncProgress(
                        currentFile: remoteName, action: "Uploading",
                        bytesTransferred: totalBytesTransferred, totalBytes: size,
                        filesCompleted: completed, filesTotal: totalActions,
                        bytesPerSecond: Self.speed(bytes: totalBytesTransferred, since: syncStart)
                    ))

                    let _ = try await apiClient.uploadFile(data: data, filename: remoteName, parentID: task.remoteFolderID)
                    let hash = SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
                    try db.updateState(taskID: taskID, fileName: remoteName, contentHash: hash)
                    totalBytesTransferred += size
                    result.uploaded += 1
                    result.fileActivity.append(ActivityItem(filename: remoteName, action: "uploaded", timestamp: Date()))
                    logger.info(" Uploaded: \(remoteName) (\(size) bytes)")

                case .download(let fileID, let localPath, let remoteName):
                    onProgress(SyncProgress(
                        currentFile: remoteName, action: "Downloading",
                        bytesTransferred: totalBytesTransferred, totalBytes: 0,
                        filesCompleted: completed, filesTotal: totalActions,
                        bytesPerSecond: Self.speed(bytes: totalBytesTransferred, since: syncStart)
                    ))

                    let data = try await apiClient.downloadFile(id: fileID)
                    let url = URL(fileURLWithPath: localPath)
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: url)
                    let hash = SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
                    try db.updateState(taskID: taskID, fileName: remoteName, contentHash: hash)
                    let size = Int64(data.count)
                    totalBytesTransferred += size
                    result.downloaded += 1
                    result.fileActivity.append(ActivityItem(filename: remoteName, action: "downloaded", timestamp: Date()))
                    logger.info(" Downloaded: \(remoteName) (\(size) bytes)")

                case .deleteRemote(let fileID, let remoteName):
                    try await apiClient.deleteFile(id: fileID)
                    try db.removeState(taskID: taskID, fileName: remoteName)
                    result.deleted += 1
                    result.fileActivity.append(ActivityItem(filename: remoteName, action: "deleted", timestamp: Date()))

                case .deleteLocal(let path, let remoteName):
                    try FileManager.default.removeItem(atPath: path)
                    try db.removeState(taskID: taskID, fileName: remoteName)
                    result.deleted += 1
                    result.fileActivity.append(ActivityItem(filename: remoteName, action: "deleted", timestamp: Date()))

                case .conflict(let localPath, let remoteID, let remoteName):
                    let data = try await apiClient.downloadFile(id: remoteID)
                    let url = URL(fileURLWithPath: localPath)
                    let conflictName = Self.conflictName(for: url.lastPathComponent)
                    let conflictPath = url.deletingLastPathComponent().appendingPathComponent(conflictName)
                    try FileManager.default.moveItem(at: url, to: conflictPath)
                    try data.write(to: url)
                    let hash = SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
                    try db.updateState(taskID: taskID, fileName: remoteName, contentHash: hash)
                    result.conflicts += 1
                    result.fileActivity.append(ActivityItem(filename: "\(remoteName) (conflict)", action: "downloaded", timestamp: Date()))
                }

                completed += 1
            } catch let error as APIError where error == .unauthorized {
                // Re-throw auth errors so AppState can re-authenticate
                logger.info(" Auth failed on \(action) — re-throwing for re-auth")
                throw error
            } catch {
                logger.info(" Action failed: \(action) — \(error)")
                result.errors += 1
            }
        }

        return result
    }

    private static func speed(bytes: Int64, since: Date) -> Double {
        let elapsed = Date().timeIntervalSince(since)
        guard elapsed > 0 else { return 0 }
        return Double(bytes) / elapsed
    }

    private func scanLocalFiles(at path: String, excludePatterns: [String]) -> [LocalFileInfo] {
        var files: [LocalFileInfo] = []
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: path) else { return files }

        while let relativePath = enumerator.nextObject() as? String {
            // Check exclude patterns
            if excludePatterns.contains(where: { matchPattern($0, against: relativePath) }) {
                continue
            }

            let fullPath = (path as NSString).appendingPathComponent(relativePath)
            guard let attrs = try? fm.attributesOfItem(atPath: fullPath) else { continue }
            let isDir = attrs[.type] as? FileAttributeType == .typeDirectory
            let size = (attrs[.size] as? Int64) ?? 0
            let modified = (attrs[.modificationDate] as? Date) ?? Date()

            // Compute hash for files (not dirs)
            var hash: String? = nil
            if !isDir, let data = fm.contents(atPath: fullPath) {
                hash = SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
            }

            files.append(LocalFileInfo(
                relativePath: relativePath,
                fullPath: fullPath,
                isDirectory: isDir,
                size: size,
                modifiedAt: modified,
                contentHash: hash
            ))
        }
        return files
    }

    private func determineActions(local: [LocalFileInfo], remote: [ServerFile], known: [String: SyncFileState], mode: SyncTask.SyncMode, basePath: String) -> [SyncAction] {
        var actions: [SyncAction] = []
        let remoteByName = Dictionary(uniqueKeysWithValues: remote.filter { !$0.isDir }.map { ($0.name, $0) })
        let localByName = Dictionary(uniqueKeysWithValues: local.filter { !$0.isDirectory }.map { (URL(fileURLWithPath: $0.relativePath).lastPathComponent, $0) })

        // Check local files against remote
        for (name, localFile) in localByName {
            if let remoteFile = remoteByName[name] {
                // Both exist — check if changed
                if localFile.contentHash != remoteFile.contentHash {
                    let knownHash = known[name]?.contentHash
                    if knownHash == remoteFile.contentHash {
                        // Only local changed -> upload
                        actions.append(.upload(localFile.fullPath, name))
                    } else if knownHash == localFile.contentHash {
                        // Only remote changed -> download (if two-way)
                        if mode == .twoWay {
                            let localPath = (basePath as NSString).appendingPathComponent(name)
                            actions.append(.download(remoteFile.id, localPath, name))
                        }
                    } else {
                        // Both changed -> conflict
                        if mode == .twoWay {
                            actions.append(.conflict(localFile.fullPath, remoteFile.id, name))
                        } else {
                            actions.append(.upload(localFile.fullPath, name))
                        }
                    }
                }
            } else {
                // Local only -> upload
                actions.append(.upload(localFile.fullPath, name))
            }
        }

        // Check remote files not in local (two-way only)
        if mode == .twoWay {
            for (name, remoteFile) in remoteByName {
                if localByName[name] == nil {
                    if known[name] != nil {
                        // Was known but deleted locally -> delete remote
                        actions.append(.deleteRemote(remoteFile.id, name))
                    } else {
                        // New remote file -> download
                        let localPath = (basePath as NSString).appendingPathComponent(name)
                        actions.append(.download(remoteFile.id, localPath, name))
                    }
                }
            }
        }

        return actions
    }

    private func matchPattern(_ pattern: String, against path: String) -> Bool {
        let name = URL(fileURLWithPath: path).lastPathComponent
        if pattern.hasPrefix("*") {
            return name.hasSuffix(String(pattern.dropFirst()))
        }
        return name == pattern
    }

    static func conflictName(for filename: String) -> String {
        let url = URL(fileURLWithPath: filename)
        let name = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let host = Host.current().localizedName ?? "unknown"
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = formatter.string(from: Date())
        if ext.isEmpty {
            return "\(name)_\(host)_\(timestamp)"
        }
        return "\(name)_\(host)_\(timestamp).\(ext)"
    }
}

struct LocalFileInfo {
    let relativePath: String
    let fullPath: String
    let isDirectory: Bool
    let size: Int64
    let modifiedAt: Date
    let contentHash: String?
}

struct SyncProgress {
    var currentFile: String
    var action: String          // "Uploading", "Downloading"
    var bytesTransferred: Int64
    var totalBytes: Int64
    var filesCompleted: Int
    var filesTotal: Int
    var bytesPerSecond: Double
}

struct SyncResult {
    var uploaded: Int
    var downloaded: Int
    var deleted: Int
    var conflicts: Int
    var errors: Int
    var fileActivity: [ActivityItem]
}

enum SyncAction: CustomStringConvertible {
    case upload(String, String)              // localPath, remoteName
    case download(String, String, String)    // remoteFileID, localPath, remoteName
    case deleteRemote(String, String)        // remoteFileID, remoteName
    case deleteLocal(String, String)         // localPath, remoteName
    case conflict(String, String, String)    // localPath, remoteFileID, remoteName

    var description: String {
        switch self {
        case .upload(_, let name): return "upload(\(name))"
        case .download(_, _, let name): return "download(\(name))"
        case .deleteRemote(_, let name): return "deleteRemote(\(name))"
        case .deleteLocal(_, let name): return "deleteLocal(\(name))"
        case .conflict(_, _, let name): return "conflict(\(name))"
        }
    }
}
