import Foundation

/// URLSession delegate that reports upload progress per byte and handles completion.
class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, URLSessionDataDelegate {
    let totalBytes: Int64
    let onProgress: ((Int64, Int64) -> Void)?
    var continuation: CheckedContinuation<ServerFile, Error>?
    var session: URLSession?
    var responseData = Data()

    init(totalBytes: Int64, onProgress: ((Int64, Int64) -> Void)?) {
        self.totalBytes = totalBytes
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        onProgress?(totalBytesSent, totalBytes)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        responseData.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer { self.session?.finishTasksAndInvalidate() }
        if let error = error {
            continuation?.resume(throwing: error)
            continuation = nil
            return
        }
        guard let http = task.response as? HTTPURLResponse, http.statusCode < 400 else {
            continuation?.resume(throwing: APIError.serverError((task.response as? HTTPURLResponse)?.statusCode ?? 500))
            continuation = nil
            return
        }
        do {
            let file = try JSONDecoder().decode(ServerFile.self, from: responseData)
            continuation?.resume(returning: file)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }
}

actor APIClient {
    let baseURL: String
    private var accessToken: String?
    private var refreshToken: String?
    private let session: URLSession

    init(baseURL: String) {
        self.baseURL = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 3600
        // HTTP/2 is negotiated automatically over TLS. Allow more parallel streams
        // so the parallel-upload path (up to 4 concurrent) doesn't serialize behind
        // a single connection. On HTTPS this reuses one TCP/TLS connection.
        config.httpMaximumConnectionsPerHost = 6
        config.httpShouldUsePipelining = true
        // Tell URLSession to keep connections warm between requests (reduces TCP
        // handshake overhead on many-small-request workloads like hash-check + upload).
        config.httpShouldSetCookies = false
        self.session = URLSession(configuration: config)
    }

    /// Return the current access token (for use in nonisolated upload functions).
    func currentToken() -> String? { accessToken }

    func login(username: String, password: String) async throws {
        let body = ["username": username, "password": password]
        let response: LoginResponse = try await post("/api/auth/login", body: body)
        self.accessToken = response.accessToken
        self.refreshToken = response.refreshToken

        // Store tokens in Keychain
        KeychainHelper.save(key: "access_token", value: response.accessToken)
        KeychainHelper.save(key: "refresh_token", value: response.refreshToken)
    }

    func listFiles(parentID: String? = nil) async throws -> [ServerFile] {
        var path = "/api/files"
        if let parentID = parentID {
            path += "?parent_id=\(parentID)"
        }
        let response: FilesResponse = try await get(path)
        return response.files
    }

    func listFolders(parentID: String? = nil) async throws -> [ServerFile] {
        var path = "/api/files?dirs_only=true"
        if let parentID = parentID {
            path += "&parent_id=\(parentID)"
        }
        let response: FilesResponse = try await get(path)
        return response.files
    }

    /// Stream a file download directly to disk (avoids loading into memory).
    func downloadFileToDisk(id: String, destination: URL) async throws -> Int64 {
        var request = URLRequest(url: URL(string: "\(baseURL)/api/files/\(id)/download")!)
        request.timeoutInterval = 86400 // Large file downloads need extended timeout
        addAuth(&request)
        let (tempURL, response) = try await session.download(for: request)
        try checkResponse(response)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: tempURL, to: destination)
        let attrs = try FileManager.default.attributesOfItem(atPath: destination.path)
        return attrs[.size] as? Int64 ?? 0
    }

    func deleteFile(id: String) async throws {
        try await delete("/api/files/\(id)")
    }

    func markFileRemovedLocally(id: String, removed: Bool) async throws {
        let body: [String: Any] = ["removed": removed]
        let _: EmptyResponse = try await put("/api/files/\(id)/removed-locally", body: body)
    }

    // MARK: - Sync State (for cross-device restore)

    func saveSyncStates(deviceID: String, taskName: String, states: [[String: String]]) async throws {
        let _: EmptyResponse = try await put("/api/sync-state/\(deviceID)/\(taskName)", body: states)
    }

    func getSyncStates(deviceID: String, taskName: String) async throws -> [[String: Any]] {
        let raw: [[String: String]] = try await get("/api/sync-state/\(deviceID)/\(taskName)")
        return raw.map { dict in dict.mapValues { $0 as Any } }
    }

    func getChanges(since: Date) async throws -> ChangesResponse {
        let formatter = ISO8601DateFormatter()
        let sinceStr = formatter.string(from: since)
        return try await get("/api/changes?since=\(sinceStr)")
    }

    func healthCheck() async throws -> Bool {
        let _: [String: String] = try await get("/api/health")
        return true
    }

    /// Check which hashes exist on the server. Returns a list of hashes that already exist.
    /// Used for bulk deduplication: send all local hashes, get back which ones the server already has.
    func checkHashes(_ hashes: [String]) async throws -> [String] {
        let body: [String: Any] = ["hashes": hashes]
        let response: CheckHashesResponse = try await post("/api/files/check-hashes", body: body)
        return response.existing
    }

    /// Get full recursive file tree under a folder (single API call replaces recursive listFiles).
    func getFileTree(folderID: String) async throws -> [RemoteTreeFile] {
        let response: FileTreeResponse = try await get("/api/files/tree?folder_id=\(folderID)")
        return response.files
    }

    func createTask(body: [String: Any]) async throws -> TaskResponse {
        return try await post("/api/tasks", body: body)
    }

    func deleteTask(id: String) async throws {
        try await delete("/api/tasks/\(id)")
    }

    // MARK: - Task Retention Policy

    func getTaskRetention(taskID: String) async throws -> RetentionPolicy {
        return try await get("/api/tasks/\(taskID)/retention")
    }

    func setTaskRetention(taskID: String, policy: RetentionPolicy) async throws {
        let body: [String: Any] = [
            "hourly": policy.hourly,
            "daily": policy.daily,
            "weekly": policy.weekly,
            "monthly": policy.monthly,
            "yearly": policy.yearly
        ]
        let _: RetentionPolicy = try await put("/api/tasks/\(taskID)/retention", body: body)
    }

    // MARK: - Notifications

    func getNotifications() async throws -> NotificationsResponse {
        return try await get("/api/notifications")
    }

    func acceptNotification(id: String) async throws {
        let _: EmptyResponse = try await post("/api/notifications/\(id)/accept", body: [:])
    }

    func declineNotification(id: String) async throws {
        let _: EmptyResponse = try await post("/api/notifications/\(id)/decline", body: [:])
    }

    // MARK: - Teams

    func getMyTeams() async throws -> MyTeamsResponse {
        return try await get("/api/teams/mine")
    }

    func updateTeam(id: String, name: String?, quotaBytes: Int64?) async throws {
        var body: [String: Any] = [:]
        if let name = name { body["name"] = name }
        if let quota = quotaBytes { body["quota_bytes"] = quota }
        let _: TeamInfo = try await put("/api/teams/\(id)", body: body)
    }

    // MARK: - Admin: User Transfer

    func transferUser(fromUserID: String, toUserID: String) async throws {
        let body: [String: Any] = ["to_user_id": toUserID]
        let _: EmptyResponse = try await post("/api/admin/users/\(fromUserID)/transfer", body: body)
    }

    // MARK: - Admin: Backups

    func listBackups() async throws -> BackupsResponse {
        return try await get("/api/admin/backups")
    }

    func createBackup() async throws -> BackupEntry {
        return try await post("/api/admin/backups", body: [:])
    }

    func downloadBackup(id: String) async throws -> Data {
        return try await getData("/api/admin/backups/\(id)/download")
    }

    func uploadBackup(data: Data, filename: String) async throws -> BackupEntry {
        let boundary = UUID().uuidString
        var request = URLRequest(url: URL(string: "\(baseURL)/api/admin/backups/upload")!)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        addAuth(&request)

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (responseData, response) = try await session.data(for: request)
        try checkResponse(response)
        return try JSONDecoder().decode(BackupEntry.self, from: responseData)
    }

    func restoreBackup(id: String) async throws {
        let _: EmptyResponse = try await post("/api/admin/backups/\(id)/restore", body: [:])
    }

    // MARK: - File Provider support

    func setToken(_ token: String) {
        self.accessToken = token
    }

    func getFile(id: String) async throws -> ServerFile {
        // GET /api/files/{id} — fall back to listing and matching by ID
        let files: FilesResponse = try await get("/api/files")
        guard let file = files.files.first(where: { $0.id == id }) else {
            throw APIError.serverError(404)
        }
        return file
    }

    func createFolder(name: String, parentID: String) async throws -> ServerFile {
        let body: [String: Any] = ["name": name, "parent_id": parentID, "is_dir": true]
        // Use raw post to handle the minimal server response
        var request = URLRequest(url: URL(string: "\(baseURL)/api/files")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        addAuth(&request)
        let (data, response) = try await session.data(for: request)
        try checkResponse(response)
        // Decode as dictionary first, then build ServerFile
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = dict["id"] as? String,
              let name = dict["name"] as? String else {
            throw APIError.invalidResponse
        }
        return ServerFile(
            id: id, parentID: dict["parent_id"] as? String, name: name,
            isDir: (dict["is_dir"] as? Bool) ?? true, size: (dict["size"] as? Int64) ?? 0,
            contentHash: dict["content_hash"] as? String, mimeType: dict["mime_type"] as? String,
            createdAt: dict["created_at"] as? String, updatedAt: dict["updated_at"] as? String,
            deletedAt: dict["deleted_at"] as? String, removedLocally: dict["removed_locally"] as? Bool
        )
    }

    func moveFile(id: String, name: String, parentID: String) async throws {
        let body: [String: Any] = ["name": name, "parent_id": parentID]
        let _: [String: String] = try await put("/api/files/\(id)", body: body)
    }

    // MARK: - Direct Block Upload

    /// Check which block hashes already exist on the server.
    func checkBlocks(_ hashes: [String]) async throws -> [String] {
        let body: [String: Any] = ["hashes": hashes]
        let response: CheckHashesResponse = try await post("/api/blocks/check", body: body)
        return response.existing
    }

    /// Upload a single block directly to storage. Nonisolated for parallel uploads.
    nonisolated static func uploadBlock(baseURL: String, token: String, hash: String, data: Data) async throws {
        var lastError: Error?
        for attempt in 1...3 {
            do {
                var request = URLRequest(url: URL(string: "\(baseURL)/api/blocks/\(hash)")!)
                request.httpMethod = "PUT"
                request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                request.timeoutInterval = 86400
                request.httpBody = data

                let (_, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode < 400 else {
                    throw APIError.serverError((response as? HTTPURLResponse)?.statusCode ?? 500)
                }
                return
            } catch {
                lastError = error
                let nsError = error as NSError
                let retryableCodes = [-1005, -1001, -1009, -1004, -1003] // connection lost, timeout, not connected, can't connect, can't find host
                if nsError.domain == NSURLErrorDomain && retryableCodes.contains(nsError.code) && attempt < 3 {
                    try await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
                    continue
                }
                throw error
            }
        }
        throw lastError!
    }

    /// Upload file via raw PUT with per-byte progress reporting.
    func uploadFileStreaming(fileURL: URL, parentID: String, onProgress: ((Int64, Int64) -> Void)? = nil) async throws -> ServerFile {
        let filename = fileURL.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? fileURL.lastPathComponent
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0

        var request = URLRequest(url: URL(string: "\(baseURL)/api/files/put?parent_id=\(parentID)&filename=\(filename)")!)
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        if let token = accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        // Dynamic timeout: 60s base + 1s per MB (small files don't wait 1 hour)
        let timeoutSeconds = max(60, Double(fileSize) / 1_000_000 + 60)
        request.timeoutInterval = timeoutSeconds

        let delegate = UploadProgressDelegate(totalBytes: fileSize, onProgress: onProgress)

        let result: ServerFile = try await withCheckedThrowingContinuation { continuation in
            delegate.continuation = continuation
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = timeoutSeconds
            config.timeoutIntervalForResource = 7200
            let uploadSession = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
            let task = uploadSession.uploadTask(with: request, fromFile: fileURL)
            delegate.session = uploadSession
            task.resume()
        }
        return result
    }

    /// Direct upload (alias for streaming).
    func uploadFileDirect(fileURL: URL, parentID: String) async throws -> ServerFile {
        return try await uploadFileStreaming(fileURL: fileURL, parentID: parentID)
    }

    // MARK: - Resumable upload

    struct InitUploadResponse: Codable {
        let upload_id: String
        let chunk_size: Int64
        let total_chunks: Int
    }

    struct UploadStatusResponse: Codable {
        let upload_id: String
        let filename: String
        let total_chunks: Int
        let received_chunks: [Int]
        let complete: Bool
    }

    /// Start a resumable upload session. Returns upload_id + chunk layout.
    func initResumableUpload(filename: String, parentID: String, totalSize: Int64, chunkSize: Int64 = 0) async throws -> InitUploadResponse {
        let body: [String: Any] = [
            "filename": filename,
            "parent_id": parentID,
            "total_size": totalSize,
            "chunk_size": chunkSize
        ]
        return try await post("/api/uploads/init", body: body)
    }

    /// Query which chunks have been received (for resume after failure).
    func getResumableUploadStatus(uploadID: String) async throws -> UploadStatusResponse {
        return try await get("/api/uploads/\(uploadID)/status")
    }

    /// Upload a single chunk with retry on transient network errors.
    /// The chunk body is passed as raw bytes (no multipart wrapper).
    nonisolated static func uploadChunk(baseURL: String, token: String, uploadID: String, chunkIndex: Int, fileURL: URL, offset: Int64, length: Int) async throws {
        var lastError: Error?
        for attempt in 1...3 {
            do {
                let url = URL(string: "\(baseURL)/api/uploads/\(uploadID)/chunks/\(chunkIndex)")!
                var request = URLRequest(url: url)
                request.httpMethod = "PUT"
                request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                // Dynamic per-chunk timeout: 60s base + 1s/MB
                let mbChunk = max(1.0, Double(length) / 1_000_000)
                request.timeoutInterval = 60 + mbChunk

                // Read the exact chunk window to a temp file → uploadTask(fromFile:).
                // This streams from disk instead of loading the chunk into memory.
                let tmpURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("syncvault-chunk-\(UUID().uuidString).bin")
                defer { try? FileManager.default.removeItem(at: tmpURL) }

                let inHandle = try FileHandle(forReadingFrom: fileURL)
                defer { try? inHandle.close() }
                try inHandle.seek(toOffset: UInt64(offset))
                let chunkData = inHandle.readData(ofLength: length)
                try chunkData.write(to: tmpURL)

                let config = URLSessionConfiguration.ephemeral
                config.timeoutIntervalForRequest = request.timeoutInterval
                config.timeoutIntervalForResource = request.timeoutInterval * 2
                let session = URLSession(configuration: config)
                defer { session.finishTasksAndInvalidate() }

                let (_, response) = try await session.upload(for: request, fromFile: tmpURL)
                guard let http = response as? HTTPURLResponse, http.statusCode < 400 else {
                    throw APIError.serverError((response as? HTTPURLResponse)?.statusCode ?? 500)
                }
                return
            } catch {
                lastError = error
                let nsError = error as NSError
                let retryableCodes = [-1005, -1001, -1009, -1004, -1003, -1017]
                if nsError.domain == NSURLErrorDomain && retryableCodes.contains(nsError.code) && attempt < 3 {
                    try await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
                    continue
                }
                throw error
            }
        }
        throw lastError!
    }

    /// Finalize a resumable upload — assembles chunks server-side + creates file record.
    func completeResumableUpload(uploadID: String) async throws -> ServerFile {
        return try await post("/api/uploads/\(uploadID)/complete", body: [:])
    }

    // MARK: - Tar-batch upload

    struct TarBatchResult: Codable {
        let uploaded: [TarEntry]
        struct TarEntry: Codable {
            let relative_path: String
            let file: ServerFile?
            let error: String?
        }
    }

    /// Upload a tar archive containing many files in a single HTTP request.
    /// Much faster than individual PUTs for directories with many small files
    /// (eliminates per-file HTTP overhead).
    /// The tar file is streamed from disk via uploadTask(fromFile:) so memory
    /// stays bounded regardless of archive size.
    func uploadTarBatch(tarFileURL: URL, parentID: String) async throws -> TarBatchResult {
        let tarSize = (try? FileManager.default.attributesOfItem(atPath: tarFileURL.path)[.size] as? Int64) ?? 0
        var request = URLRequest(url: URL(string: "\(baseURL)/api/files/batch-tar?parent_id=\(parentID)")!)
        request.httpMethod = "POST"
        request.setValue("application/x-tar", forHTTPHeaderField: "Content-Type")
        if let token = accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = max(120, Double(tarSize) / 1_000_000 + 60)

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = request.timeoutInterval
        config.timeoutIntervalForResource = request.timeoutInterval * 2
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        let (data, response) = try await session.upload(for: request, fromFile: tarFileURL)
        guard let http = response as? HTTPURLResponse, http.statusCode < 400 else {
            throw APIError.serverError((response as? HTTPURLResponse)?.statusCode ?? 500)
        }
        return try JSONDecoder().decode(TarBatchResult.self, from: data)
    }

    /// Orchestrate a resumable upload for a local file. Resumes existing sessions if the
    /// passed `existingUploadID` is still valid server-side. Reports progress per chunk.
    /// Returns the final ServerFile on success.
    func uploadFileResumable(
        fileURL: URL,
        parentID: String,
        fileSize: Int64,
        existingUploadID: String? = nil,
        onProgress: ((Int64, Int64) -> Void)? = nil,
        onUploadIDAssigned: ((String) -> Void)? = nil
    ) async throws -> ServerFile {
        var uploadID = ""
        var chunkSize: Int64 = 0
        var totalChunks = 0
        var receivedChunks: Set<Int> = []

        // Try to resume existing session
        if let existing = existingUploadID {
            do {
                let status = try await getResumableUploadStatus(uploadID: existing)
                uploadID = status.upload_id
                totalChunks = status.total_chunks
                receivedChunks = Set(status.received_chunks)
                // Compute chunk size from fileSize + totalChunks
                chunkSize = Int64(ceil(Double(fileSize) / Double(max(1, totalChunks))))
                syncLog("Resuming upload \(uploadID): \(receivedChunks.count)/\(totalChunks) chunks already done")
            } catch {
                // Session expired/invalid — start fresh
                syncLog("Resume failed (\(error.localizedDescription)), starting new upload session")
            }
        }

        if uploadID.isEmpty {
            let init_ = try await initResumableUpload(
                filename: fileURL.lastPathComponent,
                parentID: parentID,
                totalSize: fileSize
            )
            uploadID = init_.upload_id
            chunkSize = init_.chunk_size
            totalChunks = init_.total_chunks
            onUploadIDAssigned?(uploadID)
        }

        let token = self.accessToken ?? ""
        let base = self.baseURL
        // Report already-completed chunks as progress
        var bytesSent: Int64 = Int64(receivedChunks.count) * chunkSize
        if bytesSent > fileSize { bytesSent = fileSize }
        onProgress?(bytesSent, fileSize)

        for i in 0..<totalChunks {
            if receivedChunks.contains(i) { continue }
            let offset = Int64(i) * chunkSize
            let length = min(Int(chunkSize), Int(fileSize - offset))
            if length <= 0 { break }
            try await APIClient.uploadChunk(
                baseURL: base, token: token,
                uploadID: uploadID, chunkIndex: i,
                fileURL: fileURL, offset: offset, length: length
            )
            bytesSent += Int64(length)
            onProgress?(min(bytesSent, fileSize), fileSize)
        }

        return try await completeResumableUpload(uploadID: uploadID)
    }

    /// Batch upload multiple small files in a single HTTP request.
    /// Returns array of created ServerFile objects.
    func batchUpload(files: [(url: URL, parentID: String)]) async throws -> [ServerFile] {
        let boundary = UUID().uuidString
        var request = URLRequest(url: URL(string: "\(baseURL)/api/files/batch-upload")!)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let token = accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 300

        var body = Data()
        // Use the first file's parentID as shared parent (all files in same dir)
        if let first = files.first {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"parent_id\"\r\n\r\n\(first.parentID)\r\n".data(using: .utf8)!)
        }

        for file in files {
            let fileData = try Data(contentsOf: file.url)
            let filename = file.url.lastPathComponent
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\nContent-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
            body.append(fileData)
            body.append("\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode < 400 else {
            throw APIError.serverError((response as? HTTPURLResponse)?.statusCode ?? 500)
        }

        struct BatchResponse: Codable {
            let files: [ServerFile]
        }
        let result = try JSONDecoder().decode(BatchResponse.self, from: data)
        return result.files
    }

    // MARK: - Integrity Check

    struct IntegrityResult: Codable {
        let folderID: String
        let fileCount: Int
        let dirCount: Int
        let totalSize: Int64

        enum CodingKeys: String, CodingKey {
            case folderID = "folder_id"
            case fileCount = "file_count"
            case dirCount = "dir_count"
            case totalSize = "total_size"
        }
    }

    func getIntegrity(folderID: String) async throws -> IntegrityResult {
        return try await get("/api/files/\(folderID)/integrity")
    }

    // MARK: - Delta Sync

    /// Block signature from server (256KB block with weak + strong hash)
    struct BlockSignature: Codable {
        let index: Int
        let weak_hash: UInt32
        let strong_hash: String
    }

    struct BlocksResponse: Codable {
        let file_id: String
        let block_size: Int
        let blocks: [BlockSignature]
    }

    /// Fetch block signatures for an existing file (for delta comparison)
    func getBlockSignatures(fileID: String) async throws -> BlocksResponse {
        let response: BlocksResponse = try await get("/api/files/\(fileID)/blocks")
        return response
    }

    /// Upload delta — only changed blocks. Much faster than full upload for modified files.
    ///
    /// Body is streamed from a temp file via URLSession.uploadTask(fromFile:) so we never
    /// hold more than one 8 MB write buffer in memory, even for hundreds of MB of delta data.
    func uploadDelta(fileID: String, reuseBlocks: [Int], newBlocksData: Data, newBlockEntries: [(index: Int, offset: Int)]) async throws -> ServerFile {
        let boundary = UUID().uuidString

        // Build manifest JSON
        struct DeltaManifest: Codable {
            let reuse_blocks: [Int]
            let new_blocks: [NewBlock]
        }
        struct NewBlock: Codable {
            let index: Int
            let offset: Int64
        }
        let manifest = DeltaManifest(
            reuse_blocks: reuseBlocks,
            new_blocks: newBlockEntries.map { NewBlock(index: $0.index, offset: Int64($0.offset)) }
        )
        let manifestJSON = try JSONEncoder().encode(manifest)

        // Stream the multipart body to a temp file to keep memory usage bounded.
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("syncvault-delta-\(UUID().uuidString).bin")
        FileManager.default.createFile(atPath: tmpURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        guard let handle = try? FileHandle(forWritingTo: tmpURL) else {
            throw NSError(domain: "DeltaSync", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not create temp file for delta body"])
        }

        let manifestHeader = "--\(boundary)\r\nContent-Disposition: form-data; name=\"manifest\"\r\n\r\n"
        let dataHeader = "\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"data\"; filename=\"delta.bin\"\r\nContent-Type: application/octet-stream\r\n\r\n"
        let footer = "\r\n--\(boundary)--\r\n"

        // Write parts sequentially (streaming) — no intermediate Data accumulation beyond the
        // newBlocksData we were passed.
        try handle.write(contentsOf: manifestHeader.data(using: .utf8)!)
        try handle.write(contentsOf: manifestJSON)
        try handle.write(contentsOf: dataHeader.data(using: .utf8)!)
        try handle.write(contentsOf: newBlocksData)
        try handle.write(contentsOf: footer.data(using: .utf8)!)
        try handle.close()

        let bodySize = (try? FileManager.default.attributesOfItem(atPath: tmpURL.path)[.size] as? Int64) ?? 0

        var request = URLRequest(url: URL(string: "\(baseURL)/api/files/\(fileID)/delta")!)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let token = accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        // Dynamic timeout matching the streaming uploader: 60s base + 1s/MB.
        let timeoutSeconds = max(60, Double(bodySize) / 1_000_000 + 60)
        request.timeoutInterval = timeoutSeconds

        let delegate = UploadProgressDelegate(totalBytes: bodySize, onProgress: nil)
        let result: ServerFile = try await withCheckedThrowingContinuation { continuation in
            delegate.continuation = continuation
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = timeoutSeconds
            config.timeoutIntervalForResource = 7200
            let uploadSession = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
            let task = uploadSession.uploadTask(with: request, fromFile: tmpURL)
            delegate.session = uploadSession
            task.resume()
        }
        return result
    }

    /// Create a file on the server from pre-uploaded blocks.
    func createFileFromBlocks(filename: String, parentID: String, fileHash: String, blocks: [[String: Any]]) async throws -> ServerFile {
        let body: [String: Any] = [
            "filename": filename,
            "parent_id": parentID,
            "file_hash": fileHash,
            "blocks": blocks
        ]
        return try await post("/api/files/from-blocks", body: body)
    }

    // MARK: - Private HTTP methods

    /// Execute a request with automatic retry on -1005 (stale connection).
    private func execute(_ request: URLRequest) async throws -> (Data, URLResponse) {
        var lastError: Error?
        for attempt in 1...3 {
            do {
                return try await session.data(for: request)
            } catch {
                lastError = error
                let nsError = error as NSError
                if nsError.domain == NSURLErrorDomain && nsError.code == -1005 && attempt < 3 {
                    try await Task.sleep(nanoseconds: UInt64(attempt) * 500_000_000)
                    continue
                }
                throw error
            }
        }
        throw lastError!
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        var request = URLRequest(url: URL(string: "\(baseURL)\(path)")!)
        request.httpMethod = "GET"
        addAuth(&request)
        let (data, response) = try await execute(request)
        try checkResponse(response)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func getData(_ path: String) async throws -> Data {
        var request = URLRequest(url: URL(string: "\(baseURL)\(path)")!)
        request.httpMethod = "GET"
        addAuth(&request)
        let (data, response) = try await execute(request)
        try checkResponse(response)
        return data
    }

    private func post<T: Decodable>(_ path: String, body: Any) async throws -> T {
        var request = URLRequest(url: URL(string: "\(baseURL)\(path)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        addAuth(&request)
        let (data, response) = try await execute(request)
        try checkResponse(response)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func delete(_ path: String) async throws {
        var request = URLRequest(url: URL(string: "\(baseURL)\(path)")!)
        request.httpMethod = "DELETE"
        addAuth(&request)
        let (_, response) = try await execute(request)
        try checkResponse(response)
    }

    private func put<T: Decodable>(_ path: String, body: Any) async throws -> T {
        var request = URLRequest(url: URL(string: "\(baseURL)\(path)")!)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        addAuth(&request)
        let (data, response) = try await execute(request)
        try checkResponse(response)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func addAuth(_ request: inout URLRequest) {
        if let token = accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }

    private func checkResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        if http.statusCode == 401 {
            throw APIError.unauthorized
        }
        if http.statusCode >= 400 {
            throw APIError.serverError(http.statusCode)
        }
    }

    /// Re-authenticate using saved credentials from Keychain
    func reAuthenticate() async -> Bool {
        guard let password = KeychainHelper.load(key: "server_password"),
              let username = KeychainHelper.load(key: "saved_username") else { return false }
        do {
            try await login(username: username, password: password)
            return true
        } catch {
            return false
        }
    }
}

// MARK: - Notification & Team response types

struct NotificationsResponse: Codable {
    let notifications: [AppNotification]
    let unread_count: Int
}

struct AppNotification: Codable, Identifiable {
    let id: String
    let type: String
    let title: String
    let message: String
    let data: String?
    let read: Bool
    let acted: Bool
    let created_at: String
}

struct MyTeamsResponse: Codable {
    let teams: [TeamInfo]
}

struct TeamInfo: Codable, Identifiable {
    let id: String
    let name: String
    let permission: String
    let quota_bytes: Int64?
}

struct RetentionPolicy: Codable {
    var hourly: Int
    var daily: Int
    var weekly: Int
    var monthly: Int
    var yearly: Int

    static var `default`: RetentionPolicy {
        RetentionPolicy(hourly: 24, daily: 7, weekly: 4, monthly: 12, yearly: 3)
    }
}

struct BackupsResponse: Codable {
    let backups: [BackupEntry]
}

struct BackupEntry: Codable, Identifiable {
    let id: String
    let filename: String
    let size_bytes: Int64
    let created_at: String
}

// Used for POST endpoints that return an empty or minimal body
private struct EmptyResponse: Codable {}

// MARK: - Hash check / file tree models

/// Response from POST /api/files/check-hashes.
/// Server returns which hashes from our list already exist in storage.
struct CheckHashesResponse: Codable {
    let existing: [String]
}

struct FileTreeResponse: Codable {
    let files: [RemoteTreeFile]
}

struct RemoteTreeFile: Codable {
    let id: String
    let name: String
    let relativePath: String
    let size: Int64
    let contentHash: String?
    let isDir: Bool
    let removedLocally: Bool?
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, name, size
        case relativePath = "relative_path"
        case contentHash = "content_hash"
        case isDir = "is_dir"
        case removedLocally = "removed_locally"
        case updatedAt = "updated_at"
    }
}

enum APIError: Error, LocalizedError, Equatable {
    case unauthorized
    case serverError(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .unauthorized: return "Authentication failed"
        case .serverError(let code): return "Server error (\(code))"
        case .invalidResponse: return "Invalid server response"
        }
    }
}
