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

    init(apiClient: APIClient, db: SyncDatabase) {
        self.apiClient = apiClient
        self.db = db
    }

    /// Sync a task. changedPaths == nil means full scan (first sync).
    func syncTask(_ task: SyncTask, changedPaths: Set<String>?, onProgress: @Sendable @escaping (SyncProgress) async -> Void = { _ in }) async throws -> SyncResult {
        guard !isRunning else { return SyncResult(uploaded: 0, downloaded: 0, deleted: 0, conflicts: 0, errors: 0, fileActivity: []) }
        isRunning = true
        defer { isRunning = false }

        var result = SyncResult(uploaded: 0, downloaded: 0, deleted: 0, conflicts: 0, errors: 0, fileActivity: [])
        let basePath = task.localPath
        let isFullScan = (changedPaths == nil)

        // Reset folder cache each sync
        folderIDCache = [:]
        folderIDCache[""] = task.remoteFolderID  // root = task's remote folder

        // 1. Scan local files
        let localFiles: [LocalFileInfo]
        if isFullScan {
            logger.info("Full scan: \(basePath)")
            localFiles = scanLocalFiles(at: basePath, excludePatterns: task.excludePatterns)
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

        // 3. Determine actions using relative paths (server is source of truth — no known state)
        let actions: [SyncAction]
        if isFullScan {
            actions = determineActions(local: localFiles, remote: remoteTree, mode: task.mode, basePath: basePath)
        } else {
            actions = determineIncrementalActions(changedLocal: localFiles, remote: remoteTree, mode: task.mode, basePath: basePath)
        }

        logger.info(" Actions: \(actions.count)")
        for a in actions.prefix(10) {
            logger.info("   \(a)")
        }

        // 5. Sort: uploads small files first (large last), other actions first
        let sortedActions = actions.sorted { a, b in
            let sizeOf: (SyncAction) -> Int64 = { action in
                if case .upload(let path, _, _) = action {
                    return (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
                }
                return 0
            }
            let aIsUpload = { if case .upload = a { return true }; return false }()
            let bIsUpload = { if case .upload = b { return true }; return false }()
            if aIsUpload && bIsUpload { return sizeOf(a) < sizeOf(b) }
            if aIsUpload { return false } // non-uploads first
            if bIsUpload { return true }
            return false
        }

        // 6. Execute all actions (no limit), uploads in parallel with adaptive concurrency
        let total = sortedActions.count
        let bytes = ActorCounter()
        let completed = ActorCounter()
        let start = Date()
        let names = sortedActions.map { $0.fileName }
        var authFailed = false

        let semaphore = DynamicSemaphore(initialLimit: 4)

        await withTaskGroup(of: (SyncActionResult).self) { group in
            for (i, action) in sortedActions.enumerated() {
                group.addTask {
                    await semaphore.wait()
                    defer { Task { await semaphore.signal() } }

                    let pending = Array(names.dropFirst(i + 1).prefix(5))
                    let curBytes = await bytes.value
                    let curCompleted = Int(await completed.value)

                    do {
                        switch action {
                        case .upload(let path, let relativePath, let remoteFileID):
                            let fileURL = URL(fileURLWithPath: path)
                            let attrs = try FileManager.default.attributesOfItem(atPath: path)
                            let fileSize = (attrs[.size] as? Int64) ?? 0
                            let displayName = URL(fileURLWithPath: relativePath).lastPathComponent

                            // Dynamically adjust parallelism based on file size
                            let optimalParallel = DynamicSemaphore.parallelismFor(fileSize: fileSize)
                            await semaphore.setLimit(optimalParallel)

                            await onProgress(SyncProgress(
                                currentFile: displayName, action: "Uploading",
                                bytesTransferred: curBytes, totalBytes: fileSize,
                                filesCompleted: curCompleted, filesTotal: total,
                                bytesPerSecond: Self.speed(bytes: curBytes, since: start),
                                pendingFiles: pending
                            ))

                            // Ensure parent directories exist on server
                            let parentRelPath = (relativePath as NSString).deletingLastPathComponent
                            let parentID = try await self.ensureRemoteDirectory(parentRelPath, rootID: task.remoteFolderID)

                            let CHUNK_THRESHOLD: Int64 = 50 * 1024 * 1024  // 50 MB
                            var uploadedHash: String

                            if fileSize > CHUNK_THRESHOLD {
                                // Large file — chunked upload (8MB chunks, resumable)
                                let chunkStart = Date()
                                let chunkCounter = ActorCounter()
                                let result = try await self.uploadChunked(fileURL: fileURL, filename: displayName, parentID: parentID, fileSize: fileSize) { chunkSize in
                                    await chunkCounter.add(chunkSize)
                                    await bytes.add(chunkSize)
                                    let transferred = await chunkCounter.value
                                    let speed = Double(transferred) / max(Date().timeIntervalSince(chunkStart), 0.1)
                                    await onProgress(SyncProgress(
                                        currentFile: displayName, action: "Uploading",
                                        bytesTransferred: transferred, totalBytes: fileSize,
                                        filesCompleted: curCompleted, filesTotal: total,
                                        bytesPerSecond: speed,
                                        pendingFiles: pending
                                    ))
                                }
                                uploadedHash = result.contentHash
                            } else {
                                // Small file — stream upload
                                let result = try await self.apiClient.uploadFileFromDisk(fileURL: fileURL, filename: displayName, parentID: parentID)
                                uploadedHash = result.contentHash ?? ""
                            }

                            // Server now holds the canonical hash — no local state to update
                            logger.info(" Uploaded: \(relativePath) (\(fileSize) bytes, hash: \(uploadedHash))")
                            await bytes.add(fileSize)
                            return .uploaded(displayName)

                        case .download(let fileID, let localPath, let relativePath):
                            let displayName = URL(fileURLWithPath: relativePath).lastPathComponent
                            await onProgress(SyncProgress(
                                currentFile: displayName, action: "Downloading",
                                bytesTransferred: curBytes, totalBytes: 0,
                                filesCompleted: curCompleted, filesTotal: total,
                                bytesPerSecond: Self.speed(bytes: curBytes, since: start),
                                pendingFiles: pending
                            ))

                            let data = try await self.apiClient.downloadFile(id: fileID)
                            let url = URL(fileURLWithPath: localPath)
                            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                            try data.write(to: url)
                            let size = Int64(data.count)
                            await bytes.add(size)
                            logger.info(" Downloaded: \(relativePath) (\(size) bytes)")
                            return .downloaded(displayName)

                        case .markRemovedLocally(let fileID, let relativePath):
                            try await self.apiClient.markFileRemovedLocally(id: fileID, removed: true)
                            let displayName = URL(fileURLWithPath: relativePath).lastPathComponent
                            logger.info(" Marked removed locally: \(relativePath)")
                            return .markedRemoved(displayName)

                        case .deleteLocal(let path, let relativePath):
                            try FileManager.default.removeItem(atPath: path)
                            let displayName = URL(fileURLWithPath: relativePath).lastPathComponent
                            return .deletedLocal(displayName)

                        case .conflict(let localPath, let remoteID, let relativePath):
                            let displayName = URL(fileURLWithPath: relativePath).lastPathComponent
                            let data = try await self.apiClient.downloadFile(id: remoteID)
                            let url = URL(fileURLWithPath: localPath)
                            let conflictName = Self.conflictName(for: displayName)
                            let conflictPath = url.deletingLastPathComponent().appendingPathComponent(conflictName)
                            try FileManager.default.moveItem(at: url, to: conflictPath)
                            try data.write(to: url)
                            return .conflict(displayName)

                        case .createDirectory(let relativePath):
                            let _ = try await self.ensureRemoteDirectory(relativePath, rootID: task.remoteFolderID)
                            let displayName = URL(fileURLWithPath: relativePath).lastPathComponent
                            logger.info(" Created dir: \(relativePath)")
                            return .uploaded(displayName)
                        }
                    } catch let error as APIError where error == .unauthorized {
                        logger.info(" Auth failed — re-throwing")
                        return .authFailed
                    } catch {
                        logger.info(" Failed: \(action) — \(error)")
                        return .error
                    }
                }
            }

            for await actionResult in group {
                switch actionResult {
                case .uploaded(let name):
                    result.uploaded += 1
                    result.fileActivity.append(ActivityItem(filename: name, action: "uploaded", timestamp: Date()))
                    await completed.increment()
                case .downloaded(let name):
                    result.downloaded += 1
                    result.fileActivity.append(ActivityItem(filename: name, action: "downloaded", timestamp: Date()))
                    await completed.increment()
                case .markedRemoved(let name):
                    result.deleted += 1
                    result.fileActivity.append(ActivityItem(filename: name, action: "removed locally", timestamp: Date()))
                    await completed.increment()
                case .deletedLocal(let name):
                    result.deleted += 1
                    result.fileActivity.append(ActivityItem(filename: name, action: "deleted", timestamp: Date()))
                    await completed.increment()
                case .conflict(let name):
                    result.conflicts += 1
                    result.fileActivity.append(ActivityItem(filename: "\(name) (conflict)", action: "downloaded", timestamp: Date()))
                    await completed.increment()
                case .authFailed:
                    authFailed = true
                case .error:
                    result.errors += 1
                    await completed.increment()
                }
            }
        }

        if authFailed {
            throw APIError.unauthorized
        }

        return result
    }

    // MARK: - Sync State Export/Restore

    func exportSyncStates(taskID: String) -> [[String: String]] {
        guard let states = try? db.getStates(taskID: taskID) else { return [] }
        return states.values.map { state in
            ["file_name": state.fileName, "content_hash": state.contentHash]
        }
    }

    func restoreSyncStates(taskID: String, states: [[String: Any]]) throws {
        for stateDict in states {
            guard let fileName = stateDict["file_name"] as? String,
                  let contentHash = stateDict["content_hash"] as? String else { continue }
            try db.updateState(taskID: taskID, fileName: fileName, contentHash: contentHash)
        }
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

    /// Full scan: hash every file — server is the source of truth, no local cache.
    private func scanLocalFiles(at path: String, excludePatterns: [String]) -> [LocalFileInfo] {
        var files: [LocalFileInfo] = []
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: path) else { return files }

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
                hash = try? Self.hashFile(at: URL(fileURLWithPath: fullPath))
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

            // File no longer exists → mark as deleted
            guard let attrs = try? fm.attributesOfItem(atPath: changedPath) else {
                files.append(LocalFileInfo(
                    relativePath: relativePath,
                    fullPath: changedPath,
                    isDirectory: false,
                    size: 0,
                    modifiedAt: Date(),
                    contentHash: nil,
                    deletedLocally: true
                ))
                continue
            }

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

    /// Full scan: compare all local vs all remote using server as the source of truth.
    private func determineActions(local: [LocalFileInfo], remote: [RemoteFileInfo], mode: SyncTask.SyncMode, basePath: String) -> [SyncAction] {
        var actions: [SyncAction] = []

        // Build maps by relative path (files only)
        let localByPath = Dictionary(local.filter { !$0.isDirectory }.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })
        let remoteByPath = Dictionary(remote.filter { !$0.isDir }.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })

        // Create empty directories on server
        let localDirs = local.filter { $0.isDirectory }
        let remoteDirPaths = Set(folderIDCache.keys)
        for dir in localDirs {
            if !remoteDirPaths.contains(dir.relativePath) {
                actions.append(.createDirectory(dir.relativePath))
            }
        }

        // Local files: check against server
        for (relPath, localFile) in localByPath {
            if let remoteFile = remoteByPath[relPath] {
                // Both exist — compare hashes
                if localFile.contentHash != remoteFile.contentHash {
                    // Different → upload (local wins, server keeps versions)
                    actions.append(.upload(localFile.fullPath, relPath, remoteFile.id))
                }
                // Same hash → skip (already synced)
            } else {
                // Only local → upload
                actions.append(.upload(localFile.fullPath, relPath, nil))
            }
        }

        // Remote files not local (two-way only)
        if mode == .twoWay {
            let fm = FileManager.default
            for (relPath, remoteFile) in remoteByPath {
                if localByPath[relPath] == nil {
                    let localPath = (basePath as NSString).appendingPathComponent(relPath)
                    if fm.fileExists(atPath: localPath) {
                        // File exists locally but wasn't scanned (maybe excluded) — skip
                    } else if remoteFile.removedLocally == true {
                        // Was marked as removed locally — don't re-download
                    } else {
                        // Not local, not removed → download
                        actions.append(.download(remoteFile.id, localPath, relPath))
                    }
                }
            }
        }

        return actions
    }

    /// Incremental: only changed local + new remote. No known state — hash is the truth.
    private func determineIncrementalActions(changedLocal: [LocalFileInfo], remote: [RemoteFileInfo], mode: SyncTask.SyncMode, basePath: String) -> [SyncAction] {
        var actions: [SyncAction] = []
        let remoteByPath = Dictionary(remote.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })

        for localFile in changedLocal where !localFile.isDirectory {
            let relPath = localFile.relativePath

            // File deleted locally
            if localFile.deletedLocally {
                if mode == .twoWay, let remoteFile = remoteByPath[relPath] {
                    actions.append(.markRemovedLocally(remoteFile.id, relPath))
                }
                continue
            }

            if let remoteFile = remoteByPath[relPath] {
                // Both exist — compare hashes
                if localFile.contentHash != remoteFile.contentHash {
                    // Different hash → upload (local wins)
                    actions.append(.upload(localFile.fullPath, relPath, remoteFile.id))
                }
            } else {
                // Only local → upload
                actions.append(.upload(localFile.fullPath, relPath, nil))
            }
        }

        // New remote files not local → download (two-way only)
        if mode == .twoWay {
            let fm = FileManager.default
            let localPaths = Set(changedLocal.map { $0.relativePath })
            for (relPath, remoteFile) in remoteByPath {
                if !localPaths.contains(relPath) {
                    let localPath = (basePath as NSString).appendingPathComponent(relPath)
                    if !fm.fileExists(atPath: localPath) && remoteFile.removedLocally != true {
                        actions.append(.download(remoteFile.id, localPath, relPath))
                    }
                }
            }
        }

        return actions
    }

    // MARK: - Fast Upload Helpers

    private func uploadChunked(fileURL: URL, filename: String, parentID: String, fileSize: Int64, onChunkUploaded: ((Int64) async -> Void)? = nil) async throws -> ChunkedUploadResult {
        let chunkSize = 64 * 1024 * 1024  // 64 MB chunks — less overhead per chunk

        // 1. Init session
        let session = try await apiClient.initChunkedUpload(filename: filename, parentID: parentID, totalSize: fileSize, chunkSize: chunkSize)

        // 2. Check if we can resume (might have partial upload from before)
        let status = try await apiClient.getUploadStatus(uploadID: session.uploadID)
        let receivedSet = Set(status.receivedChunks)

        // 3. Upload missing chunks — dynamic parallel based on file size
        let missingChunks = (0..<session.totalChunks).filter { !receivedSet.contains($0) }
        let chunkParallel = DynamicSemaphore.parallelismFor(fileSize: fileSize)
        let chunkSemaphore = DynamicSemaphore(initialLimit: chunkParallel)

        try await withThrowingTaskGroup(of: Int64.self) { group in
            for i in missingChunks {
                group.addTask {
                    await chunkSemaphore.wait()
                    defer { Task { await chunkSemaphore.signal() } }

                    let handle = try FileHandle(forReadingFrom: fileURL)
                    defer { handle.closeFile() }
                    handle.seek(toFileOffset: UInt64(i) * UInt64(chunkSize))
                    let data = handle.readData(ofLength: chunkSize)

                    try await self.apiClient.uploadChunk(uploadID: session.uploadID, chunkIndex: i, data: data)

                    return Int64(data.count)
                }
            }
            for try await size in group {
                await onChunkUploaded?(size)
            }
        }

        // 4. Complete
        return try await apiClient.completeChunkedUpload(uploadID: session.uploadID)
    }

    private func uploadDelta(fileURL: URL, remoteFileID: String, relativePath: String) async throws -> Bool {
        // 1. Get remote block signatures
        let blocksResponse = try await apiClient.getFileBlocks(id: remoteFileID)

        // 2. Read local file in blocks and compare
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { handle.closeFile() }

        let blockSize = blocksResponse.blockSize
        let remoteBlocks = Dictionary(uniqueKeysWithValues: blocksResponse.blocks.map { ($0.index, $0) })

        var reuseBlocks: [Int] = []
        var newBlocks: [(index: Int, data: Data)] = []
        var blockIndex = 0

        while true {
            let data = handle.readData(ofLength: blockSize)
            if data.isEmpty { break }

            let localHash = SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()

            if let remote = remoteBlocks[blockIndex], remote.strongHash == localHash {
                reuseBlocks.append(blockIndex)
            } else {
                newBlocks.append((index: blockIndex, data: data))
            }
            blockIndex += 1
        }

        // 3. If more than 50% changed, full upload is faster — fall back
        let totalBlocks = blockIndex
        if newBlocks.count > totalBlocks / 2 { return false }

        // 4. Build and upload delta
        let manifest = DeltaManifest(
            reuseBlocks: reuseBlocks,
            newBlocks: newBlocks.map { DeltaManifestBlock(index: $0.index, offset: 0) }
        )
        let newData = newBlocks.reduce(Data()) { $0 + $1.data }
        let _ = try await apiClient.uploadDelta(fileID: remoteFileID, manifest: manifest, newBlockData: newData)
        return true
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
    var deletedLocally: Bool = false
}

/// Remote file with its relative path in the folder tree.
struct RemoteFileInfo {
    let id: String
    let name: String
    let relativePath: String
    let contentHash: String?
    let size: Int64
    var isDir: Bool = false
    var removedLocally: Bool? = nil
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
    case upload(String, String, String?)     // localPath, relativePath, remoteFileID (nil = new file)
    case download(String, String, String)    // remoteFileID, localPath, relativePath
    case markRemovedLocally(String, String)  // remoteFileID, relativePath
    case deleteLocal(String, String)         // localPath, relativePath
    case conflict(String, String, String)    // localPath, remoteFileID, relativePath
    case createDirectory(String)             // relativePath

    var fileName: String {
        switch self {
        case .upload(_, let p, _): return URL(fileURLWithPath: p).lastPathComponent
        case .download(_, _, let p): return URL(fileURLWithPath: p).lastPathComponent
        case .markRemovedLocally(_, let p): return URL(fileURLWithPath: p).lastPathComponent
        case .deleteLocal(_, let p): return URL(fileURLWithPath: p).lastPathComponent
        case .conflict(_, _, let p): return URL(fileURLWithPath: p).lastPathComponent
        case .createDirectory(let p): return URL(fileURLWithPath: p).lastPathComponent
        }
    }

    var description: String {
        switch self {
        case .upload(_, let p, _): return "upload(\(p))"
        case .download(_, _, let p): return "download(\(p))"
        case .markRemovedLocally(_, let p): return "markRemovedLocally(\(p))"
        case .deleteLocal(_, let p): return "deleteLocal(\(p))"
        case .conflict(_, _, let p): return "conflict(\(p))"
        case .createDirectory(let p): return "createDir(\(p))"
        }
    }
}

// MARK: - Async helpers

/// Simple actor-based semaphore for limiting concurrency in task groups.
actor AsyncSemaphore {
    private var count: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { count = limit }

    func wait() async {
        if count > 0 {
            count -= 1
        } else {
            await withCheckedContinuation { cont in
                waiters.append(cont)
            }
        }
    }

    func signal() {
        if waiters.isEmpty {
            count += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// Dynamic semaphore that adjusts concurrency based on file size.
/// Small files: 2 parallel (overhead dominates)
/// Medium files: 4 parallel
/// Large files: 8 parallel
/// Very large files: 16 parallel (maximize throughput)
actor DynamicSemaphore {
    private var count: Int
    private var currentLimit: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(initialLimit: Int) {
        self.count = initialLimit
        self.currentLimit = initialLimit
    }

    /// Returns the optimal parallelism level for a given file size
    static func parallelismFor(fileSize: Int64) -> Int {
        switch fileSize {
        case ..<(10 * 1024 * 1024):          return 2   // < 10 MB
        case ..<(100 * 1024 * 1024):         return 4   // 10-100 MB
        case ..<(1024 * 1024 * 1024):        return 8   // 100 MB - 1 GB
        default:                              return 16  // > 1 GB
        }
    }

    func wait() async {
        if count > 0 {
            count -= 1
        } else {
            await withCheckedContinuation { cont in
                waiters.append(cont)
            }
        }
    }

    func signal() {
        if waiters.isEmpty {
            count += 1
        } else {
            waiters.removeFirst().resume()
        }
    }

    /// Adjust the concurrency limit dynamically
    func setLimit(_ newLimit: Int) {
        if newLimit > currentLimit {
            let diff = newLimit - currentLimit
            currentLimit = newLimit
            count += diff
            while count > 0 && !waiters.isEmpty {
                count -= 1
                waiters.removeFirst().resume()
            }
        } else if newLimit < currentLimit {
            currentLimit = newLimit
        }
    }
}

/// Thread-safe counter for use inside task groups.
actor ActorCounter {
    private(set) var value: Int64 = 0

    func add(_ n: Int64) { value += n }
    func increment() { value += 1 }
}

/// Result type for individual sync actions executed in a task group.
private enum SyncActionResult {
    case uploaded(String)
    case downloaded(String)
    case markedRemoved(String)
    case deletedLocal(String)
    case conflict(String)
    case authFailed
    case error
}
