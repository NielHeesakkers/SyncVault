import Foundation
import CryptoKit
import os

private let logger = Logger(subsystem: "com.syncvault.app", category: "SyncEngine")

actor SyncEngine {
    private let apiClient: APIClient
    private let db: SyncDatabase
    private var isRunning = false

    /// Mark a file as currently syncing (for FinderSync badges)
    static func markSyncingFile(_ path: String) {
        let defaults = UserDefaults(suiteName: "DE59N86W33.com.syncvault.shared")
        var files = defaults?.stringArray(forKey: "syncingFiles") ?? []
        if !files.contains(path) {
            files.append(path)
            if files.count > 100 { files = Array(files.suffix(50)) } // Keep bounded
            defaults?.set(files, forKey: "syncingFiles")
        }
    }
    /// Cache of relative directory path -> server folder ID (built during sync)
    private var folderIDCache: [String: String] = [:]
    /// Upload speed limit in bytes per second (0 = unlimited)
    private let uploadLimitBytesPerSecond: Int64
    /// Download speed limit in bytes per second (0 = unlimited)
    private let downloadLimitBytesPerSecond: Int64

    init(apiClient: APIClient, db: SyncDatabase, uploadLimitBytesPerSecond: Int64 = 0, downloadLimitBytesPerSecond: Int64 = 0) {
        self.apiClient = apiClient
        self.db = db
        self.uploadLimitBytesPerSecond = uploadLimitBytesPerSecond
        self.downloadLimitBytesPerSecond = downloadLimitBytesPerSecond
    }

    // MARK: - Main Sync Entry Point

    /// Sync a task. changedPaths == nil means full scan (first sync or reconnect).
    func syncTask(_ task: SyncTask, changedPaths: Set<String>?, lastSyncDate: Date?, onProgress: @Sendable @escaping (SyncProgress) async -> Void = { _ in }) async throws -> SyncResult {
        guard !isRunning else { return SyncResult(uploaded: 0, downloaded: 0, deleted: 0, conflicts: 0, errors: 0, fileActivity: []) }
        isRunning = true
        defer { isRunning = false }

        var result = SyncResult(uploaded: 0, downloaded: 0, deleted: 0, conflicts: 0, errors: 0, fileActivity: [])
        let basePath = task.localPath
        let isFullScan = (changedPaths == nil)

        // Reset folder cache each sync
        folderIDCache = [:]
        folderIDCache[""] = task.remoteFolderID

        if isFullScan {
            // Phase 1 (initial sync) or Phase 3 (reconnect after offline)
            result = try await performFullSync(task: task, basePath: basePath, lastSyncDate: lastSyncDate, onProgress: onProgress)
        } else if let changed = changedPaths, !changed.isEmpty {
            // Phase 2: FSEvents-driven incremental sync
            result = try await performIncrementalSync(task: task, basePath: basePath, changedPaths: changed, onProgress: onProgress)
        } else {
            logger.info("No changes detected, skipping sync for \(task.remoteFolderName)")
        }

        return result
    }

    // MARK: - Phase 1/3: Full Sync (Hash-Check Based)

    /// Full sync using the server hash-check endpoint to avoid re-uploads.
    /// If lastSyncDate is available, only hashes files modified since then (Phase 3 reconnect).
    private func performFullSync(task: SyncTask, basePath: String, lastSyncDate: Date?, onProgress: @Sendable @escaping (SyncProgress) async -> Void) async throws -> SyncResult {
        var result = SyncResult(uploaded: 0, downloaded: 0, deleted: 0, conflicts: 0, errors: 0, fileActivity: [])

        // 1. Get remote file tree in one API call (replaces recursive listFiles)
        logger.info("Fetching remote file tree for \(task.remoteFolderName)...")
        let remoteTree = try await apiClient.getFileTree(folderID: task.remoteFolderID)
        let remoteByPath = Dictionary(remoteTree.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })

        // Build folder ID cache from remote tree
        for file in remoteTree where file.isDir {
            folderIDCache[file.relativePath] = file.id
        }
        logger.info("Remote tree: \(remoteTree.count) entries")

        // 2. Scan local files — only hash files modified since lastSyncDate (Phase 3 optimization)
        logger.info("Scanning local files at \(basePath)...")
        let localFiles = scanLocalFiles(at: basePath, excludePatterns: task.excludePatterns, lastSyncDate: lastSyncDate)
        logger.info("Local files: \(localFiles.count) total")

        // 3. Collect hashes of all local files that need checking
        var localHashMap: [String: String] = [:]   // relativePath -> hash
        var localFileMap: [String: LocalFileInfo] = [:] // relativePath -> info
        var localDirs: [LocalFileInfo] = []

        for file in localFiles {
            if file.isDirectory {
                localDirs.append(file)
                continue
            }
            localFileMap[file.relativePath] = file
            if let hash = file.contentHash {
                localHashMap[file.relativePath] = hash
            }
        }

        // 4. Ask server which hashes already exist (bulk dedup check)
        let allHashes = Array(Set(localHashMap.values))  // Unique hashes only
        var existingHashes: Set<String> = []
        if !allHashes.isEmpty {
            logger.info("Checking \(allHashes.count) unique hashes against server...")
            let hashResponse = try await apiClient.checkHashes(allHashes)
            existingHashes = Set(hashResponse)
            logger.info("Server already has \(existingHashes.count) of \(allHashes.count) unique hashes")
        }

        // 5. Build actions using the change journal for correct delete/rename detection
        var actions: [SyncAction] = []
        var skippedBytes: Int64 = 0
        let fm = FileManager.default

        // Load the change journal — what we knew about at last sync
        let journal = (try? db.getStates(taskID: task.id.uuidString)) ?? [:]
        let journalIsEmpty = journal.isEmpty
        let localDirPaths = Set(localDirs.map { $0.relativePath })
        let remoteDirPaths = Set(folderIDCache.keys)

        // If journal is empty (first run after update), populate it without any delete actions.
        // This establishes the baseline — next sync will correctly detect changes.
        if journalIsEmpty {
            logger.info("Journal empty — populating baseline (no delete actions this cycle)")
        }

        // Create missing directories on server (local dirs not on server)
        for dir in localDirs {
            if !remoteDirPaths.contains(dir.relativePath) {
                actions.append(.createDirectory(dir.relativePath))
            }
        }

        // Determine file uploads
        for (relPath, localFile) in localFileMap {
            guard let hash = localFile.contentHash else {
                if remoteByPath[relPath] != nil {
                    skippedBytes += localFile.size
                    continue
                }
                if let fullHash = try? Self.hashFile(at: URL(fileURLWithPath: localFile.fullPath)) {
                    if let remote = remoteByPath[relPath], remote.contentHash == fullHash {
                        skippedBytes += localFile.size
                        continue
                    }
                    actions.append(.upload(localFile.fullPath, relPath, remoteByPath[relPath]?.id))
                }
                continue
            }

            if let remote = remoteByPath[relPath] {
                if remote.contentHash == hash {
                    skippedBytes += localFile.size
                    continue
                }
                // Hashes differ — check journal for conflict detection (two-way only)
                if task.mode == .twoWay, let journalEntry = journal[relPath] {
                    let localChanged = (hash != journalEntry.contentHash)
                    let remoteChanged = (remote.contentHash != journalEntry.contentHash)
                    if localChanged && remoteChanged {
                        // CONFLICT — both sides modified since last sync
                        let localPath = localFile.fullPath
                        actions.append(.conflict(localPath, remote.id, relPath))
                        logger.info("Conflict detected: \(relPath) (local and remote both changed)")
                        continue
                    }
                    if remoteChanged && !localChanged {
                        // Only remote changed → download
                        let localPath = (basePath as NSString).appendingPathComponent(relPath)
                        actions.append(.download(remote.id, localPath, relPath))
                        continue
                    }
                }
                // Only local changed (or no journal entry / upload-only) → upload
                actions.append(.upload(localFile.fullPath, relPath, remote.id))
            } else {
                actions.append(.upload(localFile.fullPath, relPath, nil))
            }
        }

        // Two-way sync: use journal for correct delete detection
        if task.mode == .twoWay {

            // Remote entries not present locally
            for (relPath, remoteFile) in remoteByPath {
                let localPath = (basePath as NSString).appendingPathComponent(relPath)
                let existsLocally = remoteFile.isDir ? fm.fileExists(atPath: localPath) : localFileMap[relPath] != nil || fm.fileExists(atPath: localPath)

                if !existsLocally {
                    if !journalIsEmpty && journal[relPath] != nil {
                        // WAS in journal → we knew about it → we deleted it locally → delete from server
                        actions.append(.deleteRemote(remoteFile.id, relPath))
                    } else if journalIsEmpty {
                        // Journal empty (first run) → don't download, just record in journal
                        // Skip — baseline will be set after this sync
                    } else {
                        // NOT in journal → new on server → download/create locally
                        if remoteFile.isDir {
                            try? fm.createDirectory(atPath: localPath, withIntermediateDirectories: true)
                            logger.info("Created local directory: \(relPath)")
                        } else if !(remoteFile.removedLocally ?? false) {
                            actions.append(.download(remoteFile.id, localPath, relPath))
                        }
                    }
                }
            }

            // Local entries not present on server (only if journal has baseline)
            if !journalIsEmpty {
                for (relPath, localFile) in localFileMap {
                    if remoteByPath[relPath] == nil {
                        if journal[relPath] != nil {
                            // WAS in journal → we knew about it → server deleted it → delete locally
                            actions.append(.deleteLocal(localFile.fullPath, relPath))
                        }
                    }
                }

                // Local directories not on server
                for dir in localDirs {
                    if remoteByPath[dir.relativePath] == nil && journal[dir.relativePath] != nil {
                        let localPath = (basePath as NSString).appendingPathComponent(dir.relativePath)
                        if fm.fileExists(atPath: localPath) {
                            actions.append(.deleteLocal(localPath, dir.relativePath))
                        }
                    }
                }
            }
        }

        logger.info("Actions: \(actions.count) (from full sync), skipped \(skippedBytes) bytes (already synced)")

        // 6. Execute actions
        result = try await executeActions(actions, task: task, skippedBytes: skippedBytes, onProgress: onProgress)

        // 7. Update change journal: snapshot of everything that should exist
        // This is the union of local + remote that survived this sync cycle
        var journalEntries: [(relativePath: String, contentHash: String, isDir: Bool)] = []

        // Add all local files that still exist
        for (relPath, localFile) in localFileMap {
            let localPath = localFile.fullPath
            if FileManager.default.fileExists(atPath: localPath) {
                journalEntries.append((relPath, localFile.contentHash ?? "", false))
            }
        }
        // Add all local directories that still exist
        for dir in localDirs {
            let localPath = (basePath as NSString).appendingPathComponent(dir.relativePath)
            if FileManager.default.fileExists(atPath: localPath) {
                journalEntries.append((dir.relativePath, "", true))
            }
        }
        // Add remote items that exist locally (downloaded this cycle or existed before)
        for (relPath, remote) in remoteByPath {
            let localPath = (basePath as NSString).appendingPathComponent(relPath)
            if FileManager.default.fileExists(atPath: localPath) {
                if !journalEntries.contains(where: { $0.relativePath == relPath }) {
                    journalEntries.append((relPath, remote.contentHash ?? "", remote.isDir))
                }
            }
        }
        try? db.replaceAllStates(taskID: task.id.uuidString, files: journalEntries)
        logger.info("Journal updated: \(journalEntries.count) entries")

        return result
    }

    // MARK: - Phase 2: Incremental Sync (FSEvents)

    /// Incremental sync: only process FSEvents-reported changes.
    /// Hashes only the changed files, checks against server, uploads if different.
    private func performIncrementalSync(task: SyncTask, basePath: String, changedPaths: Set<String>, onProgress: @Sendable @escaping (SyncProgress) async -> Void) async throws -> SyncResult {
        logger.info("Incremental sync: \(changedPaths.count) changed paths")

        // 1. Scan only the changed files
        let changedFiles = scanChangedFiles(basePath: basePath, changedPaths: changedPaths, excludePatterns: task.excludePatterns)

        // 2. Get remote tree for comparison
        let remoteTree = try await apiClient.getFileTree(folderID: task.remoteFolderID)
        let remoteByPath = Dictionary(remoteTree.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })

        // Build folder ID cache
        for file in remoteTree where file.isDir {
            folderIDCache[file.relativePath] = file.id
        }

        // 3. Build actions — detect renames first, then handle remaining changes
        var actions: [SyncAction] = []
        let journal = (try? db.getStates(taskID: task.id.uuidString)) ?? [:]

        // Separate deleted and new paths to detect renames
        var deletedPaths: [(relPath: String, localFile: LocalFileInfo)] = []
        var newPaths: [(relPath: String, localFile: LocalFileInfo)] = []
        var normalFiles: [(relPath: String, localFile: LocalFileInfo)] = []

        for localFile in changedFiles {
            let relPath = localFile.relativePath
            if localFile.deletedLocally {
                deletedPaths.append((relPath, localFile))
            } else if localFile.isDirectory && remoteByPath[relPath] == nil {
                newPaths.append((relPath, localFile))
            } else if !localFile.isDirectory && remoteByPath[relPath] == nil {
                newPaths.append((relPath, localFile))
            } else {
                normalFiles.append((relPath, localFile))
            }
        }

        // Detect renames: a deleted path that has a matching remote entry + a new path
        var handledDeletes = Set<String>()
        var handledNews = Set<String>()

        for deleted in deletedPaths {
            if let remoteFile = remoteByPath[deleted.relPath] {
                // Find a matching new path (same type: dir↔dir or file↔file)
                let isDir = remoteFile.isDir
                if let matchIdx = newPaths.firstIndex(where: { newItem in
                    !handledNews.contains(newItem.relPath) && newItem.localFile.isDirectory == isDir
                }) {
                    let newItem = newPaths[matchIdx]
                    // This is a rename: old path → new path
                    let newName = URL(fileURLWithPath: newItem.relPath).lastPathComponent
                    actions.append(.renameRemote(remoteFile.id, newName, deleted.relPath, newItem.relPath))
                    handledDeletes.insert(deleted.relPath)
                    handledNews.insert(newItem.relPath)
                    logger.info("Detected rename: \(deleted.relPath) → \(newItem.relPath)")
                }
            }
        }

        // Handle remaining deletes (not part of a rename)
        for deleted in deletedPaths where !handledDeletes.contains(deleted.relPath) {
            if task.mode == .twoWay, let remoteFile = remoteByPath[deleted.relPath] {
                actions.append(.deleteRemote(remoteFile.id, deleted.relPath))
            }
        }

        // Handle remaining new paths (not part of a rename)
        for newItem in newPaths where !handledNews.contains(newItem.relPath) {
            if newItem.localFile.isDirectory {
                actions.append(.createDirectory(newItem.relPath))
            } else {
                actions.append(.upload(newItem.localFile.fullPath, newItem.relPath, nil))
            }
        }

        // Handle normal files (existing on both sides)
        for item in normalFiles {
            let relPath = item.relPath
            let localFile = item.localFile

            if localFile.isDirectory {
                continue // Directory already exists on server
            }

            if let remoteFile = remoteByPath[relPath] {
                // Both exist - compare hashes
                if localFile.contentHash != remoteFile.contentHash {
                    // Check journal for conflict detection (two-way only)
                    if task.mode == .twoWay, let journalEntry = journal[relPath],
                       let localHash = localFile.contentHash {
                        let localChanged = (localHash != journalEntry.contentHash)
                        let remoteChanged = (remoteFile.contentHash != journalEntry.contentHash)
                        if localChanged && remoteChanged {
                            // CONFLICT — both sides modified since last sync
                            actions.append(.conflict(localFile.fullPath, remoteFile.id, relPath))
                            logger.info("Conflict detected (incremental): \(relPath)")
                            continue
                        }
                        if remoteChanged && !localChanged {
                            // Only remote changed → download
                            let localPath = (basePath as NSString).appendingPathComponent(relPath)
                            actions.append(.download(remoteFile.id, localPath, relPath))
                            continue
                        }
                    }
                    // Only local changed (or no journal entry) → upload
                    actions.append(.upload(localFile.fullPath, relPath, remoteFile.id))
                }
            } else {
                // Only local - upload
                actions.append(.upload(localFile.fullPath, relPath, nil))
            }
        }

        // Two-way: check for new remote files
        if task.mode == .twoWay {
            let fm = FileManager.default
            let localPaths = Set(changedFiles.map { $0.relativePath })
            for (relPath, remoteFile) in remoteByPath where !remoteFile.isDir {
                if !localPaths.contains(relPath) {
                    let localPath = (basePath as NSString).appendingPathComponent(relPath)
                    if !fm.fileExists(atPath: localPath) && !(remoteFile.removedLocally ?? false) {
                        actions.append(.download(remoteFile.id, localPath, relPath))
                    }
                }
            }
        }

        logger.info("Actions: \(actions.count) (from incremental sync)")

        // 4. Execute actions
        return try await executeActions(actions, task: task, onProgress: onProgress)
    }

    // MARK: - Action Execution

    /// Execute sync actions with parallel uploads, progress tracking, and error handling.
    /// skippedBytes: bytes of files that were already synced (hash matched) — used to show accurate progress.
    private func executeActions(_ actions: [SyncAction], task: SyncTask, skippedBytes: Int64 = 0, onProgress: @Sendable @escaping (SyncProgress) async -> Void) async throws -> SyncResult {
        var result = SyncResult(uploaded: 0, downloaded: 0, deleted: 0, conflicts: 0, errors: 0, fileActivity: [])

        guard !actions.isEmpty else { return result }

        for a in actions.prefix(10) {
            logger.info("  \(a)")
        }

        // Sort: non-uploads first, then uploads by size (small first)
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
            if aIsUpload { return false }
            if bIsUpload { return true }
            return false
        }

        // Calculate total bytes to transfer (uploads + downloads + skipped) for accurate progress
        var totalBytesToUpload: Int64 = skippedBytes
        for action in sortedActions {
            switch action {
            case .upload(let path, _, _):
                totalBytesToUpload += (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
            case .download(_, _, _):
                // Downloads also contribute to total transfer; size is unknown upfront,
                // so estimate conservatively. Actual bytes will be added during download.
                break
            default:
                break
            }
        }

        // Pre-create all directories sequentially to avoid 409 race conditions
        var allDirPaths = Set<String>()
        for action in sortedActions {
            switch action {
            case .upload(_, let relativePath, _):
                let parent = (relativePath as NSString).deletingLastPathComponent
                if !parent.isEmpty && parent != "." { allDirPaths.insert(parent) }
            case .createDirectory(let relativePath):
                allDirPaths.insert(relativePath)
            default: break
            }
        }
        for dirPath in allDirPaths.sorted() {
            let _ = try? await ensureRemoteDirectory(dirPath, rootID: task.remoteFolderID)
        }

        let total = sortedActions.count
        let bytesUploaded = ActorCounter(initial: skippedBytes)
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
                    let curBytes = await bytesUploaded.value
                    let curCompleted = Int(await completed.value)

                    do {
                        switch action {
                        case .upload(let path, let relativePath, let remoteFileID):
                            let fileURL = URL(fileURLWithPath: path)
                            let attrs = try FileManager.default.attributesOfItem(atPath: path)
                            let fileSize = (attrs[.size] as? Int64) ?? 0
                            let displayName = URL(fileURLWithPath: relativePath).lastPathComponent

                            // Mark as syncing for FinderSync badge
                            Self.markSyncingFile(path)

                            // Dynamically adjust parallelism based on file size
                            let optimalParallel = DynamicSemaphore.parallelismFor(fileSize: fileSize)
                            await semaphore.setLimit(optimalParallel)

                            await onProgress(SyncProgress(
                                currentFile: displayName, action: "Uploading",
                                bytesTransferred: curBytes, totalBytes: totalBytesToUpload,
                                filesCompleted: curCompleted, filesTotal: total,
                                bytesPerSecond: Self.speed(bytes: curBytes, since: start),
                                pendingFiles: pending
                            ))

                            // Ensure parent directories exist on server
                            let parentRelPath = (relativePath as NSString).deletingLastPathComponent
                            let parentID = try await self.ensureRemoteDirectory(parentRelPath, rootID: task.remoteFolderID)

                            // Direct block upload: split into 4MB blocks, upload missing, create file
                            let uploadedHash = try await self.uploadViaBlocks(fileURL: fileURL, filename: displayName, parentID: parentID, fileSize: fileSize) { blockBytes in
                                await bytesUploaded.add(blockBytes)
                                let curB = await bytesUploaded.value
                                await onProgress(SyncProgress(
                                    currentFile: displayName, action: "Uploading",
                                    bytesTransferred: curB, totalBytes: totalBytesToUpload,
                                    filesCompleted: Int(await completed.value), filesTotal: total,
                                    bytesPerSecond: Self.speed(bytes: curB, since: start),
                                    pendingFiles: pending
                                ))
                            }

                            logger.info("Uploaded: \(relativePath) (\(fileSize) bytes, hash: \(uploadedHash))")
                            try? self.db.updateState(taskID: task.id.uuidString, relativePath: relativePath, contentHash: uploadedHash, isDir: false)
                            return .uploaded(displayName)

                        case .download(let fileID, let localPath, let relativePath):
                            let displayName = URL(fileURLWithPath: relativePath).lastPathComponent
                            // Mark as syncing for FinderSync badge
                            Self.markSyncingFile(localPath)
                            await onProgress(SyncProgress(
                                currentFile: displayName, action: "Downloading",
                                bytesTransferred: curBytes, totalBytes: totalBytesToUpload,
                                filesCompleted: curCompleted, filesTotal: total,
                                bytesPerSecond: Self.speed(bytes: curBytes, since: start),
                                pendingFiles: pending
                            ))

                            let url = URL(fileURLWithPath: localPath)
                            let size = try await self.apiClient.downloadFileToDisk(id: fileID, destination: url)
                            await bytesUploaded.add(size)
                            logger.info("Downloaded: \(relativePath) (\(size) bytes)")
                            try? self.db.updateState(taskID: task.id.uuidString, relativePath: relativePath, contentHash: "", isDir: false)
                            return .downloaded(displayName)

                        case .markRemovedLocally(let fileID, let relativePath):
                            try await self.apiClient.markFileRemovedLocally(id: fileID, removed: true)
                            let displayName = URL(fileURLWithPath: relativePath).lastPathComponent
                            logger.info("Marked removed locally: \(relativePath)")
                            return .markedRemoved(displayName)

                        case .deleteRemote(let fileID, let relativePath):
                            try await self.apiClient.deleteFile(id: fileID)
                            let displayName = URL(fileURLWithPath: relativePath).lastPathComponent
                            logger.info("Deleted from server: \(relativePath)")
                            try? self.db.removeState(taskID: task.id.uuidString, relativePath: relativePath)
                            try? self.db.removeStatesUnder(taskID: task.id.uuidString, pathPrefix: relativePath)
                            return .deletedLocal(displayName)

                        case .renameRemote(let fileID, let newName, let oldRelPath, let newRelPath):
                            // Atomic rename on server — no delete + create
                            let parentRelPath = (newRelPath as NSString).deletingLastPathComponent
                            let cachedParent = await self.folderIDCache[parentRelPath]
                            let parentID = parentRelPath.isEmpty ? task.remoteFolderID : (cachedParent ?? task.remoteFolderID)
                            try await self.apiClient.moveFile(id: fileID, name: newName, parentID: parentID)
                            logger.info("Renamed on server: \(oldRelPath) → \(newRelPath)")
                            // Update journal: remove old, add new
                            try? self.db.removeState(taskID: task.id.uuidString, relativePath: oldRelPath)
                            try? self.db.removeStatesUnder(taskID: task.id.uuidString, pathPrefix: oldRelPath)
                            try? self.db.updateState(taskID: task.id.uuidString, relativePath: newRelPath, contentHash: "", isDir: true)
                            return .uploaded(newName)

                        case .deleteLocal(let path, let relativePath):
                            try FileManager.default.removeItem(atPath: path)
                            let displayName = URL(fileURLWithPath: relativePath).lastPathComponent
                            try? self.db.removeState(taskID: task.id.uuidString, relativePath: relativePath)
                            try? self.db.removeStatesUnder(taskID: task.id.uuidString, pathPrefix: relativePath)
                            return .deletedLocal(displayName)

                        case .conflict(let localPath, let remoteID, let relativePath):
                            let displayName = URL(fileURLWithPath: relativePath).lastPathComponent
                            let url = URL(fileURLWithPath: localPath)
                            let conflictName = Self.conflictName(for: displayName)
                            let conflictPath = url.deletingLastPathComponent().appendingPathComponent(conflictName)
                            // Stream the remote version directly to disk (avoids loading entire file into memory)
                            let _ = try await self.apiClient.downloadFileToDisk(id: remoteID, destination: conflictPath)
                            // Keep local version in place — it will be uploaded normally
                            logger.info("Conflict: saved remote as \(conflictName), keeping local \(displayName)")
                            return .conflict(displayName)

                        case .createDirectory(let relativePath):
                            let _ = try await self.ensureRemoteDirectory(relativePath, rootID: task.remoteFolderID)
                            let displayName = URL(fileURLWithPath: relativePath).lastPathComponent
                            logger.info("Created dir: \(relativePath)")
                            return .uploaded(displayName)
                        }
                    } catch let error as APIError where error == .unauthorized {
                        logger.info("Auth failed - re-throwing")
                        return .authFailed
                    } catch {
                        logger.info("Failed: \(action) - \(error)")
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

    // MARK: - Remote Directory Management

    /// Ensure a remote directory path exists, creating parent dirs as needed.
    /// Returns the server folder ID for the given relative path.
    /// Handles 409 gracefully by looking up the existing folder.
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

            // Try to create the folder (will 409 if exists)
            do {
                let folder = try await apiClient.createFolder(name: component, parentID: currentParentID)
                folderIDCache[currentPath] = folder.id
                currentParentID = folder.id
                logger.info("Created remote dir: \(currentPath)")
            } catch APIError.serverError(409) {
                // Folder already exists - find its ID by listing parent
                let children = try await apiClient.listFiles(parentID: currentParentID)
                if let existing = children.first(where: { $0.name == component && $0.isDir }) {
                    folderIDCache[currentPath] = existing.id
                    currentParentID = existing.id
                    logger.info("Found existing remote dir: \(currentPath) (id: \(existing.id))")
                } else {
                    logger.error("409 but folder not found in listing: \(currentPath)")
                    throw APIError.serverError(500)
                }
            }
        }

        return currentParentID
    }

    // MARK: - File Scanning

    /// Scan local files. If lastSyncDate is provided, only hash files modified since then.
    /// Files not modified since last sync are included with nil contentHash (assumed unchanged).
    private func scanLocalFiles(at path: String, excludePatterns: [String], lastSyncDate: Date?) -> [LocalFileInfo] {
        var files: [LocalFileInfo] = []
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: path) else { return files }

        var hashCount = 0
        var skipCount = 0

        while let relativePath = enumerator.nextObject() as? String {
            let name = URL(fileURLWithPath: relativePath).lastPathComponent

            // Skip hidden files, system files, and macOS metadata
            if name.hasPrefix(".") || name.hasPrefix("._") || name.hasPrefix(".smbdelete") ||
               name == ".DS_Store" || name == "Thumbs.db" || name == "desktop.ini" ||
               name == "Icon\r" || name == "Icon\r\n" || name.hasPrefix("Icon") && name.count <= 5 {
                if name.hasPrefix(".") { enumerator.skipDescendants() }
                continue
            }

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
                // Optimization: skip hashing files not modified since last sync
                if let lastSync = lastSyncDate, modified <= lastSync {
                    skipCount += 1
                    // Include file with nil hash - will be skipped unless server doesn't have it
                } else {
                    hash = try? Self.hashFile(at: URL(fileURLWithPath: fullPath))
                    hashCount += 1
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

        logger.info("Scan complete: hashed \(hashCount) files, skipped \(skipCount) unchanged files")
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

            // Path no longer exists -> mark as deleted (could be file or directory)
            guard let attrs = try? fm.attributesOfItem(atPath: changedPath) else {
                // We don't know if it was a file or dir — mark as deleted, the sync
                // engine will match it against the remote tree to find the right entry
                files.append(LocalFileInfo(
                    relativePath: relativePath,
                    fullPath: changedPath,
                    isDirectory: false,
                    size: 0,
                    modifiedAt: Date(),
                    contentHash: nil,
                    deletedLocally: true
                ))
                // Also check if there are remote children under this path (it was a directory)
                // by adding it as a directory delete too
                files.append(LocalFileInfo(
                    relativePath: relativePath,
                    fullPath: changedPath,
                    isDirectory: true,
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

    // MARK: - Sync State Export/Restore

    func exportSyncStates(taskID: String) -> [[String: String]] {
        guard let states = try? db.getStates(taskID: taskID) else { return [] }
        return states.values.map { state in
            ["file_name": state.relativePath, "content_hash": state.contentHash]
        }
    }

    func restoreSyncStates(taskID: String, states: [[String: Any]]) throws {
        for stateDict in states {
            guard let fileName = stateDict["file_name"] as? String,
                  let contentHash = stateDict["content_hash"] as? String else { continue }
            try db.updateState(taskID: taskID, relativePath: fileName, contentHash: contentHash, isDir: false)
        }
    }

    // MARK: - Direct Block Upload

    /// Public wrapper for on-demand bulk upload from AppState
    func uploadViaBlocksPublic(fileURL: URL, filename: String, parentID: String, fileSize: Int64) async throws -> String {
        return try await uploadViaBlocks(fileURL: fileURL, filename: filename, parentID: parentID, fileSize: fileSize)
    }

    /// Upload a file by splitting it into 4 MB blocks, checking which exist, and uploading only missing ones.
    /// No staging, no assembly — blocks go directly to content-addressable storage.
    private func uploadViaBlocks(fileURL: URL, filename: String, parentID: String, fileSize: Int64, onBlockUploaded: ((Int64) async -> Void)? = nil) async throws -> String {
        let blockSize = 4 * 1024 * 1024  // 4 MB — matches server storage block size
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { handle.closeFile() }

        // 1. Split file into blocks, compute hashes
        var fileHasher = SHA256()
        var blocks: [(index: Int, hash: String, size: Int, offset: UInt64)] = []
        var index = 0

        while true {
            let data = handle.readData(ofLength: blockSize)
            if data.isEmpty { break }
            fileHasher.update(data: data)
            let blockHash = SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
            blocks.append((index: index, hash: blockHash, size: data.count, offset: UInt64(index) * UInt64(blockSize)))
            index += 1
        }

        let fileHash = fileHasher.finalize().compactMap { String(format: "%02x", $0) }.joined()
        logger.info("File \(filename): \(blocks.count) blocks, hash \(fileHash)")

        // 2. Check which blocks the server already has
        let allHashes = blocks.map { $0.hash }
        let existingHashes = try await apiClient.checkBlocks(allHashes)
        let existingSet = Set(existingHashes)
        let missingBlocks = blocks.filter { !existingSet.contains($0.hash) }

        // Report already-existing blocks as progress
        let existingBytes = Int64(blocks.filter { existingSet.contains($0.hash) }.map { $0.size }.reduce(0, +))
        if existingBytes > 0 {
            await onBlockUploaded?(existingBytes)
        }

        logger.info("File \(filename): \(existingHashes.count) blocks exist, \(missingBlocks.count) to upload")

        // 3. Upload missing blocks — 10 in parallel
        if !missingBlocks.isEmpty {
            let token = await apiClient.currentToken() ?? ""
            let base = await apiClient.baseURL
            let sem = DynamicSemaphore(initialLimit: 10)
            let uploadLimit = self.uploadLimitBytesPerSecond

            try await withThrowingTaskGroup(of: Int64.self) { group in
                for block in missingBlocks {
                    group.addTask {
                        await sem.wait()
                        defer { Task { await sem.signal() } }

                        let blockHandle = try FileHandle(forReadingFrom: fileURL)
                        defer { blockHandle.closeFile() }
                        blockHandle.seek(toFileOffset: block.offset)
                        let data = blockHandle.readData(ofLength: block.size)

                        let blockStart = Date()
                        try await APIClient.uploadBlock(baseURL: base, token: token, hash: block.hash, data: data)

                        // Rate limiting: sleep if we uploaded faster than the limit allows
                        if uploadLimit > 0 {
                            let expectedDuration = Double(data.count) / Double(uploadLimit)
                            let elapsed = Date().timeIntervalSince(blockStart)
                            if elapsed < expectedDuration {
                                try await Task.sleep(nanoseconds: UInt64((expectedDuration - elapsed) * 1_000_000_000))
                            }
                        }

                        return Int64(data.count)
                    }
                }
                for try await size in group {
                    await onBlockUploaded?(size)
                }
            }
        }

        // 4. Create the file on the server from blocks (instant — no assembly needed)
        let blockManifest: [[String: Any]] = blocks.map { b in
            ["index": b.index, "hash": b.hash, "size": b.size]
        }
        let _ = try await apiClient.createFileFromBlocks(
            filename: filename,
            parentID: parentID,
            fileHash: fileHash,
            blocks: blockManifest
        )

        logger.info("Uploaded via blocks: \(filename) (\(fileSize) bytes, \(blocks.count) blocks)")
        return fileHash
    }

    // MARK: - Helpers

    static func hashFile(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { handle.closeFile() }
        let chunkSize = 4 * 1024 * 1024
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
    case deleteRemote(String, String)        // remoteFileID, relativePath — soft-delete on server
    case renameRemote(String, String, String, String) // remoteFileID, newName, oldRelPath, newRelPath
    case deleteLocal(String, String)         // localPath, relativePath
    case conflict(String, String, String)    // localPath, remoteFileID, relativePath
    case createDirectory(String)             // relativePath

    var fileName: String {
        switch self {
        case .upload(_, let p, _): return URL(fileURLWithPath: p).lastPathComponent
        case .download(_, _, let p): return URL(fileURLWithPath: p).lastPathComponent
        case .markRemovedLocally(_, let p): return URL(fileURLWithPath: p).lastPathComponent
        case .deleteRemote(_, let p): return URL(fileURLWithPath: p).lastPathComponent
        case .renameRemote(_, let name, _, _): return name
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
        case .deleteRemote(_, let p): return "deleteRemote(\(p))"
        case .renameRemote(_, let name, let old, _): return "rename(\(old) → \(name))"
        case .deleteLocal(_, let p): return "deleteLocal(\(p))"
        case .conflict(_, _, let p): return "conflict(\(p))"
        case .createDirectory(let p): return "createDir(\(p))"
        }
    }
}

// MARK: - Async helpers

/// Dynamic semaphore that adjusts concurrency based on file size.
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

    init(initial: Int64 = 0) {
        self.value = initial
    }

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
