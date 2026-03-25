import Foundation
import CryptoKit
import os

private let logger = Logger(subsystem: "com.syncvault.app", category: "SyncEngine")

actor SyncEngine {
    private let apiClient: APIClient
    private let db: SyncDatabase
    private var isRunning = false
    /// Cache of relative directory path → server folder ID (built during sync)
    private var folderIDCache: [String: String] = [:]

    init(apiClient: APIClient, dbPath: URL) throws {
        self.apiClient = apiClient
        self.db = try SyncDatabase(path: dbPath.path)
    }

    /// Sync a task. changedPaths == nil means full scan (first sync).
    func syncTask(_ task: SyncTask, changedPaths: Set<String>?, onProgress: @Sendable @escaping (SyncProgress) -> Void = { _ in }) async throws -> SyncResult {
        guard !isRunning else { return SyncResult(uploaded: 0, downloaded: 0, deleted: 0, conflicts: 0, errors: 0, fileActivity: []) }
        isRunning = true
        defer { isRunning = false }

        var result = SyncResult(uploaded: 0, downloaded: 0, deleted: 0, conflicts: 0, errors: 0, fileActivity: [])
        let taskID = task.id.uuidString
        let basePath = task.localPath
        let isFullScan = (changedPaths == nil)

        // Reset folder cache each sync
        folderIDCache = [:]
        folderIDCache[""] = task.remoteFolderID  // root = task's remote folder

        // 1. Scan local files
        let localFiles: [LocalFileInfo]
        if isFullScan {
            logger.info("Full scan: \(basePath)")
            localFiles = scanLocalFiles(at: basePath, excludePatterns: task.excludePatterns, hashMode: .modificationDateCheck(db: db, taskID: taskID))
        } else if let changed = changedPaths, !changed.isEmpty {
            logger.info("Incremental: \(changed.count) changed paths")
            localFiles = scanChangedFiles(basePath: basePath, changedPaths: changed, excludePatterns: task.excludePatterns)
        } else {
            logger.info("No local changes, checking remote only")
            localFiles = []
        }
        logger.info("Local files to process: \(localFiles.count)")

        // 2. Get ALL remote files recursively (flatten the tree)
        let remoteTree = try await fetchRemoteTree(rootID: task.remoteFolderID)
        logger.info(" Remote files (recursive): \(remoteTree.count)")

        // 3. Get known state
        let knownState = try db.getStates(taskID: taskID)
        logger.info(" Known state: \(knownState.count)")

        // 4. Determine actions using relative paths
        let actions: [SyncAction]
        if isFullScan {
            actions = determineActions(local: localFiles, remote: remoteTree, known: knownState, mode: task.mode, basePath: basePath)
        } else {
            actions = determineIncrementalActions(changedLocal: localFiles, remote: remoteTree, known: knownState, mode: task.mode, basePath: basePath)
        }

        logger.info(" Actions: \(actions.count)")
        for a in actions.prefix(10) {
            logger.info("   \(a)")
        }

        // 5. Execute (max 10 per cycle)
        let maxPerCycle = 10
        let limited = Array(actions.prefix(maxPerCycle))
        let total = actions.count
        var completed = 0
        var bytes: Int64 = 0
        let start = Date()
        let names = actions.map { $0.fileName }

        if limited.count < total {
            logger.info(" Limiting to \(maxPerCycle) of \(total)")
        }

        for (i, action) in limited.enumerated() {
            do {
                let pending = Array(names.dropFirst(i + 1).prefix(5))

                switch action {
                case .upload(let path, let relativePath):
                    let fileURL = URL(fileURLWithPath: path)
                    let attrs = try FileManager.default.attributesOfItem(atPath: path)
                    let size = (attrs[.size] as? Int64) ?? 0
                    let displayName = URL(fileURLWithPath: relativePath).lastPathComponent

                    onProgress(SyncProgress(
                        currentFile: displayName, action: "Uploading",
                        bytesTransferred: bytes, totalBytes: size,
                        filesCompleted: completed, filesTotal: total,
                        bytesPerSecond: Self.speed(bytes: bytes, since: start),
                        pendingFiles: pending
                    ))

                    // Ensure parent directories exist on server
                    let parentRelPath = (relativePath as NSString).deletingLastPathComponent
                    let parentID = try await ensureRemoteDirectory(parentRelPath, rootID: task.remoteFolderID)

                    let hash = try Self.hashFile(at: fileURL)
                    let _ = try await apiClient.uploadFileFromDisk(fileURL: fileURL, filename: displayName, parentID: parentID)
                    try db.updateState(taskID: taskID, fileName: relativePath, contentHash: hash)
                    bytes += size
                    result.uploaded += 1
                    result.fileActivity.append(ActivityItem(filename: displayName, action: "uploaded", timestamp: Date()))
                    logger.info(" Uploaded: \(relativePath) (\(size) bytes)")

                case .download(let fileID, let localPath, let relativePath):
                    let displayName = URL(fileURLWithPath: relativePath).lastPathComponent
                    onProgress(SyncProgress(
                        currentFile: displayName, action: "Downloading",
                        bytesTransferred: bytes, totalBytes: 0,
                        filesCompleted: completed, filesTotal: total,
                        bytesPerSecond: Self.speed(bytes: bytes, since: start),
                        pendingFiles: pending
                    ))

                    let data = try await apiClient.downloadFile(id: fileID)
                    let url = URL(fileURLWithPath: localPath)
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: url)
                    let hash = SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
                    try db.updateState(taskID: taskID, fileName: relativePath, contentHash: hash)
                    let size = Int64(data.count)
                    bytes += size
                    result.downloaded += 1
                    result.fileActivity.append(ActivityItem(filename: displayName, action: "downloaded", timestamp: Date()))
                    logger.info(" Downloaded: \(relativePath) (\(size) bytes)")

                case .deleteRemote(let fileID, let relativePath):
                    try await apiClient.deleteFile(id: fileID)
                    try db.removeState(taskID: taskID, fileName: relativePath)
                    result.deleted += 1
                    let displayName = URL(fileURLWithPath: relativePath).lastPathComponent
                    result.fileActivity.append(ActivityItem(filename: displayName, action: "deleted", timestamp: Date()))

                case .deleteLocal(let path, let relativePath):
                    try FileManager.default.removeItem(atPath: path)
                    try db.removeState(taskID: taskID, fileName: relativePath)
                    result.deleted += 1
                    let displayName = URL(fileURLWithPath: relativePath).lastPathComponent
                    result.fileActivity.append(ActivityItem(filename: displayName, action: "deleted", timestamp: Date()))

                case .conflict(let localPath, let remoteID, let relativePath):
                    let displayName = URL(fileURLWithPath: relativePath).lastPathComponent
                    let data = try await apiClient.downloadFile(id: remoteID)
                    let url = URL(fileURLWithPath: localPath)
                    let conflictName = Self.conflictName(for: displayName)
                    let conflictPath = url.deletingLastPathComponent().appendingPathComponent(conflictName)
                    try FileManager.default.moveItem(at: url, to: conflictPath)
                    try data.write(to: url)
                    let hash = SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
                    try db.updateState(taskID: taskID, fileName: relativePath, contentHash: hash)
                    result.conflicts += 1
                    result.fileActivity.append(ActivityItem(filename: "\(displayName) (conflict)", action: "downloaded", timestamp: Date()))
                }

                completed += 1
            } catch let error as APIError where error == .unauthorized {
                logger.info(" Auth failed — re-throwing")
                throw error
            } catch {
                logger.info(" Failed: \(action) — \(error)")
                result.errors += 1
            }
        }

        return result
    }

    // MARK: - Remote Tree

    /// Recursively fetch all files/folders from a remote folder, returning them with relative paths.
    private func fetchRemoteTree(rootID: String) async throws -> [RemoteFileInfo] {
        var allFiles: [RemoteFileInfo] = []
        try await fetchRemoteRecursive(folderID: rootID, relativePath: "", into: &allFiles)
        return allFiles
    }

    private func fetchRemoteRecursive(folderID: String, relativePath: String, into files: inout [RemoteFileInfo]) async throws {
        let children = try await apiClient.listFiles(parentID: folderID)
        for child in children {
            let childRelPath = relativePath.isEmpty ? child.name : "\(relativePath)/\(child.name)"
            if child.isDir {
                // Cache the folder ID for later use
                folderIDCache[childRelPath] = child.id
                // Recurse into subdirectory
                try await fetchRemoteRecursive(folderID: child.id, relativePath: childRelPath, into: &files)
            } else {
                files.append(RemoteFileInfo(
                    id: child.id,
                    name: child.name,
                    relativePath: childRelPath,
                    contentHash: child.contentHash,
                    size: child.size
                ))
            }
        }
    }

    /// Ensure a remote directory path exists, creating parent dirs as needed.
    /// Returns the server folder ID for the given relative path.
    private func ensureRemoteDirectory(_ relativePath: String, rootID: String) async throws -> String {
        if relativePath.isEmpty || relativePath == "." {
            return rootID
        }

        // Check cache first
        if let cached = folderIDCache[relativePath] {
            return cached
        }

        // Split into components and create each level
        let components = relativePath.split(separator: "/").map(String.init)
        var currentParentID = rootID
        var currentPath = ""

        for component in components {
            currentPath = currentPath.isEmpty ? component : "\(currentPath)/\(component)"

            if let cached = folderIDCache[currentPath] {
                currentParentID = cached
                continue
            }

            // Try to create the folder (will 409 if exists — that's ok)
            do {
                let folder = try await apiClient.createFolder(name: component, parentID: currentParentID)
                folderIDCache[currentPath] = folder.id
                currentParentID = folder.id
                logger.info(" Created remote dir: \(currentPath)")
            } catch APIError.serverError(409) {
                // Folder already exists — find its ID by listing parent
                let children = try await apiClient.listFiles(parentID: currentParentID)
                if let existing = children.first(where: { $0.name == component && $0.isDir }) {
                    folderIDCache[currentPath] = existing.id
                    currentParentID = existing.id
                } else {
                    throw APIError.serverError(500)
                }
            }
        }

        return currentParentID
    }

    // MARK: - File Scanning

    enum HashMode {
        case always
        case modificationDateCheck(db: SyncDatabase, taskID: String)
    }

    /// Full scan with smart hashing (only hash if mod date changed).
    private func scanLocalFiles(at path: String, excludePatterns: [String], hashMode: HashMode) -> [LocalFileInfo] {
        var files: [LocalFileInfo] = []
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: path) else { return files }

        var knownStates: [String: SyncFileState] = [:]
        if case .modificationDateCheck(let db, let taskID) = hashMode {
            knownStates = (try? db.getStates(taskID: taskID)) ?? [:]
        }

        while let relativePath = enumerator.nextObject() as? String {
            if excludePatterns.contains(where: { matchPattern($0, against: relativePath) }) {
                continue
            }

            let fullPath = (path as NSString).appendingPathComponent(relativePath)
            guard let attrs = try? fm.attributesOfItem(atPath: fullPath) else { continue }
            let isDir = attrs[.type] as? FileAttributeType == .typeDirectory
            let size = (attrs[.size] as? Int64) ?? 0
            let modified = (attrs[.modificationDate] as? Date) ?? Date()

            var hash: String? = nil
            if !isDir {
                if let known = knownStates[relativePath], modified <= known.syncedAt {
                    hash = known.contentHash // File unchanged
                } else {
                    hash = try? Self.hashFile(at: URL(fileURLWithPath: fullPath))
                }
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

    /// Incremental: only scan FSEvents-reported files.
    private func scanChangedFiles(basePath: String, changedPaths: Set<String>, excludePatterns: [String]) -> [LocalFileInfo] {
        var files: [LocalFileInfo] = []
        let fm = FileManager.default

        for changedPath in changedPaths {
            guard changedPath.hasPrefix(basePath) else { continue }
            let dropCount = basePath.hasSuffix("/") ? basePath.count : basePath.count + 1
            guard changedPath.count > dropCount else { continue }
            let relativePath = String(changedPath.dropFirst(dropCount))

            if excludePatterns.contains(where: { matchPattern($0, against: relativePath) }) {
                continue
            }

            guard let attrs = try? fm.attributesOfItem(atPath: changedPath) else { continue }
            let isDir = attrs[.type] as? FileAttributeType == .typeDirectory
            let size = (attrs[.size] as? Int64) ?? 0
            let modified = (attrs[.modificationDate] as? Date) ?? Date()

            var hash: String? = nil
            if !isDir {
                hash = try? Self.hashFile(at: URL(fileURLWithPath: changedPath))
            }

            files.append(LocalFileInfo(
                relativePath: relativePath,
                fullPath: changedPath,
                isDirectory: isDir,
                size: size,
                modifiedAt: modified,
                contentHash: hash
            ))
        }
        return files
    }

    // MARK: - Action Determination

    /// Full scan: compare all local vs all remote using relative paths.
    private func determineActions(local: [LocalFileInfo], remote: [RemoteFileInfo], known: [String: SyncFileState], mode: SyncTask.SyncMode, basePath: String) -> [SyncAction] {
        var actions: [SyncAction] = []
        let remoteByPath = Dictionary(remote.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })
        let localByPath = Dictionary(local.filter { !$0.isDirectory }.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })

        // Local files → upload if new/changed
        for (relPath, localFile) in localByPath {
            if let remoteFile = remoteByPath[relPath] {
                if localFile.contentHash != remoteFile.contentHash {
                    let knownHash = known[relPath]?.contentHash
                    if knownHash == remoteFile.contentHash {
                        actions.append(.upload(localFile.fullPath, relPath))
                    } else if knownHash == localFile.contentHash {
                        if mode == .twoWay {
                            let localPath = (basePath as NSString).appendingPathComponent(relPath)
                            actions.append(.download(remoteFile.id, localPath, relPath))
                        }
                    } else {
                        if mode == .twoWay {
                            actions.append(.conflict(localFile.fullPath, remoteFile.id, relPath))
                        } else {
                            actions.append(.upload(localFile.fullPath, relPath))
                        }
                    }
                }
            } else {
                actions.append(.upload(localFile.fullPath, relPath))
            }
        }

        // Remote files not in local → download (two-way only)
        if mode == .twoWay {
            for (relPath, remoteFile) in remoteByPath {
                if localByPath[relPath] == nil {
                    if known[relPath] != nil {
                        actions.append(.deleteRemote(remoteFile.id, relPath))
                    } else {
                        let localPath = (basePath as NSString).appendingPathComponent(relPath)
                        actions.append(.download(remoteFile.id, localPath, relPath))
                    }
                }
            }
        }

        return actions
    }

    /// Incremental: only changed local + new remote.
    private func determineIncrementalActions(changedLocal: [LocalFileInfo], remote: [RemoteFileInfo], known: [String: SyncFileState], mode: SyncTask.SyncMode, basePath: String) -> [SyncAction] {
        var actions: [SyncAction] = []
        let remoteByPath = Dictionary(remote.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })

        for localFile in changedLocal where !localFile.isDirectory {
            let relPath = localFile.relativePath
            if let remoteFile = remoteByPath[relPath] {
                if localFile.contentHash != remoteFile.contentHash {
                    let knownHash = known[relPath]?.contentHash
                    if knownHash == remoteFile.contentHash {
                        actions.append(.upload(localFile.fullPath, relPath))
                    } else if knownHash == localFile.contentHash {
                        if mode == .twoWay {
                            let localPath = (basePath as NSString).appendingPathComponent(relPath)
                            actions.append(.download(remoteFile.id, localPath, relPath))
                        }
                    } else {
                        if mode == .twoWay {
                            actions.append(.conflict(localFile.fullPath, remoteFile.id, relPath))
                        } else {
                            actions.append(.upload(localFile.fullPath, relPath))
                        }
                    }
                }
            } else {
                actions.append(.upload(localFile.fullPath, relPath))
            }
        }

        // New remote files
        if mode == .twoWay {
            for (relPath, remoteFile) in remoteByPath {
                if known[relPath] == nil {
                    let localPath = (basePath as NSString).appendingPathComponent(relPath)
                    actions.append(.download(remoteFile.id, localPath, relPath))
                }
            }
        }

        return actions
    }

    // MARK: - Helpers

    static func hashFile(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { handle.closeFile() }
        let chunkSize = 256 * 1024 * 1024
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        return hasher.finalize().compactMap { String(format: "%02x", $0) }.joined()
    }

    private static func speed(bytes: Int64, since: Date) -> Double {
        let elapsed = Date().timeIntervalSince(since)
        guard elapsed > 0 else { return 0 }
        return Double(bytes) / elapsed
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
        return ext.isEmpty ? "\(name)_\(host)_\(timestamp)" : "\(name)_\(host)_\(timestamp).\(ext)"
    }
}

// MARK: - Types

struct LocalFileInfo {
    let relativePath: String
    let fullPath: String
    let isDirectory: Bool
    let size: Int64
    let modifiedAt: Date
    let contentHash: String?
}

/// Remote file with its relative path in the folder tree.
struct RemoteFileInfo {
    let id: String
    let name: String
    let relativePath: String
    let contentHash: String?
    let size: Int64
}

struct SyncProgress {
    var currentFile: String
    var action: String
    var bytesTransferred: Int64
    var totalBytes: Int64
    var filesCompleted: Int
    var filesTotal: Int
    var bytesPerSecond: Double
    var pendingFiles: [String]
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
    case upload(String, String)           // localPath, relativePath
    case download(String, String, String) // remoteFileID, localPath, relativePath
    case deleteRemote(String, String)     // remoteFileID, relativePath
    case deleteLocal(String, String)      // localPath, relativePath
    case conflict(String, String, String) // localPath, remoteFileID, relativePath

    var fileName: String {
        switch self {
        case .upload(_, let p): return URL(fileURLWithPath: p).lastPathComponent
        case .download(_, _, let p): return URL(fileURLWithPath: p).lastPathComponent
        case .deleteRemote(_, let p): return URL(fileURLWithPath: p).lastPathComponent
        case .deleteLocal(_, let p): return URL(fileURLWithPath: p).lastPathComponent
        case .conflict(_, _, let p): return URL(fileURLWithPath: p).lastPathComponent
        }
    }

    var description: String {
        switch self {
        case .upload(_, let p): return "upload(\(p))"
        case .download(_, _, let p): return "download(\(p))"
        case .deleteRemote(_, let p): return "deleteRemote(\(p))"
        case .deleteLocal(_, let p): return "deleteLocal(\(p))"
        case .conflict(_, _, let p): return "conflict(\(p))"
        }
    }
}
