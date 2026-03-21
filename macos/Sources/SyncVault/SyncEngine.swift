import Foundation
import CryptoKit

actor SyncEngine {
    private let apiClient: APIClient
    private let db: SyncDatabase
    private var isRunning = false

    init(apiClient: APIClient, dbPath: URL) throws {
        self.apiClient = apiClient
        self.db = try SyncDatabase(path: dbPath.path)
    }

    func syncTask(_ task: SyncTask) async throws -> SyncResult {
        guard !isRunning else { return SyncResult(uploaded: 0, downloaded: 0, deleted: 0, conflicts: 0) }
        isRunning = true
        defer { isRunning = false }

        var result = SyncResult(uploaded: 0, downloaded: 0, deleted: 0, conflicts: 0)

        // 1. Scan local files
        let localFiles = scanLocalFiles(at: task.localPath, excludePatterns: task.excludePatterns)

        // 2. Get remote files
        let remoteFiles = try await apiClient.listFiles(parentID: task.remoteFolderID)

        // 3. Get known state from sync database
        let knownState = try db.getStates(taskID: task.id.uuidString)

        // 4. Determine actions
        let actions = determineActions(
            local: localFiles,
            remote: remoteFiles,
            known: knownState,
            mode: task.mode
        )

        // 5. Execute actions
        for action in actions {
            do {
                switch action {
                case .upload(let path, let remoteName):
                    let data = try Data(contentsOf: URL(fileURLWithPath: path))
                    let _ = try await apiClient.uploadFile(data: data, filename: remoteName, parentID: task.remoteFolderID)
                    result.uploaded += 1

                case .download(let fileID, let localPath):
                    let data = try await apiClient.downloadFile(id: fileID)
                    try data.write(to: URL(fileURLWithPath: localPath))
                    result.downloaded += 1

                case .deleteRemote(let fileID):
                    try await apiClient.deleteFile(id: fileID)
                    result.deleted += 1

                case .deleteLocal(let path):
                    try FileManager.default.removeItem(atPath: path)
                    result.deleted += 1

                case .conflict(let localPath, let remoteID):
                    // Download remote version, rename local as conflict copy
                    let data = try await apiClient.downloadFile(id: remoteID)
                    let url = URL(fileURLWithPath: localPath)
                    let conflictName = Self.conflictName(for: url.lastPathComponent)
                    let conflictPath = url.deletingLastPathComponent().appendingPathComponent(conflictName)
                    try FileManager.default.moveItem(at: url, to: conflictPath)
                    try data.write(to: url)
                    result.conflicts += 1
                }
            } catch {
                print("Sync action failed: \(error)")
            }
        }

        return result
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

    private func determineActions(local: [LocalFileInfo], remote: [ServerFile], known: [String: SyncFileState], mode: SyncTask.SyncMode) -> [SyncAction] {
        var actions: [SyncAction] = []
        let remoteByName = Dictionary(uniqueKeysWithValues: remote.map { ($0.name, $0) })
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
                            actions.append(.download(remoteFile.id, localFile.fullPath))
                        }
                    } else {
                        // Both changed -> conflict
                        if mode == .twoWay {
                            actions.append(.conflict(localFile.fullPath, remoteFile.id))
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
            for (name, remoteFile) in remoteByName where !remoteFile.isDir {
                if localByName[name] == nil {
                    if known[name] != nil {
                        // Was known but deleted locally -> delete remote
                        actions.append(.deleteRemote(remoteFile.id))
                    } else {
                        // New remote file -> download
                        let localPath = "" // Will be set by caller based on task localPath
                        actions.append(.download(remoteFile.id, localPath))
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

struct SyncResult {
    var uploaded: Int
    var downloaded: Int
    var deleted: Int
    var conflicts: Int
}

enum SyncAction {
    case upload(String, String)       // localPath, remoteName
    case download(String, String)     // remoteFileID, localPath
    case deleteRemote(String)         // remoteFileID
    case deleteLocal(String)          // localPath
    case conflict(String, String)     // localPath, remoteFileID
}
