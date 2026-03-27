import Foundation

actor APIClient {
    let baseURL: String
    private var accessToken: String?
    private var refreshToken: String?
    private let session: URLSession

    init(baseURL: String) {
        self.baseURL = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 86400
        config.timeoutIntervalForResource = 86400
        config.httpMaximumConnectionsPerHost = 6
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

    func downloadFile(id: String) async throws -> Data {
        return try await getData("/api/files/\(id)/download")
    }

    func uploadFile(data: Data, filename: String, parentID: String?) async throws -> ServerFile {
        return try await uploadMultipart("/api/files/upload", fileData: data, filename: filename, parentID: parentID)
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

    // MARK: - Authenticated Backup Download URL

    /// Returns the raw data for a backup download with auth header applied (no window.open needed).
    func downloadFileAuthenticated(id: String) async throws -> Data {
        return try await getData("/api/files/\(id)/download")
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

    // MARK: - Chunked Upload

    func initChunkedUpload(filename: String, parentID: String?, totalSize: Int64, chunkSize: Int = 64 * 1024 * 1024) async throws -> UploadSession {
        var body: [String: Any] = ["filename": filename, "total_size": totalSize, "chunk_size": chunkSize]
        if let parentID = parentID { body["parent_id"] = parentID }
        return try await post("/api/uploads/init", body: body)
    }

    func uploadChunk(uploadID: String, chunkIndex: Int, data: Data) async throws {
        let token = accessToken ?? ""
        try await Self.uploadChunkDirect(baseURL: baseURL, token: token, uploadID: uploadID, chunkIndex: chunkIndex, data: data)
    }

    /// Shared upload session — 10 parallel connections, separate from API session.
    private static let uploadSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 86400
        config.timeoutIntervalForResource = 86400
        config.httpMaximumConnectionsPerHost = 10
        return URLSession(configuration: config)
    }()

    /// Upload a chunk without actor serialization — allows truly parallel uploads.
    nonisolated static func uploadChunkDirect(baseURL: String, token: String, uploadID: String, chunkIndex: Int, data: Data) async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sv_chunk_\(uploadID)_\(chunkIndex).tmp")
        try data.write(to: tempURL)

        var lastError: Error?
        for attempt in 1...3 {
            do {
                var request = URLRequest(url: URL(string: "\(baseURL)/api/uploads/\(uploadID)/chunks/\(chunkIndex)")!)
                request.httpMethod = "PUT"
                request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                request.timeoutInterval = 86400

                let (_, response) = try await uploadSession.upload(for: request, fromFile: tempURL)
                guard let http = response as? HTTPURLResponse, http.statusCode < 400 else {
                    throw APIError.serverError((response as? HTTPURLResponse)?.statusCode ?? 500)
                }

                try? FileManager.default.removeItem(at: tempURL)
                return
            } catch {
                lastError = error
                let nsError = error as NSError
                if nsError.domain == NSURLErrorDomain && nsError.code == -1005 && attempt < 3 {
                    try await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000)
                    continue
                }
            }
        }
        try? FileManager.default.removeItem(at: tempURL)
        throw lastError!
    }

    func getUploadStatus(uploadID: String) async throws -> UploadStatus {
        return try await get("/api/uploads/\(uploadID)/status")
    }

    func completeChunkedUpload(uploadID: String) async throws -> ChunkedUploadResult {
        return try await post("/api/uploads/\(uploadID)/complete", body: [:] as [String: String])
    }

    // MARK: - Delta Sync

    func getFileBlocks(id: String) async throws -> BlocksResponse {
        return try await get("/api/files/\(id)/blocks")
    }

    func uploadDelta(fileID: String, manifest: DeltaManifest, newBlockData: Data) async throws -> ServerFile {
        let boundary = UUID().uuidString
        var request = URLRequest(url: URL(string: "\(baseURL)/api/files/\(fileID)/delta")!)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 0
        addAuth(&request)

        var body = Data()
        let manifestData = try JSONEncoder().encode(manifest)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"manifest\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/json\r\n\r\n".data(using: .utf8)!)
        body.append(manifestData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"blocks\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(newBlockData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (responseData, response) = try await session.data(for: request)
        try checkResponse(response)
        return try JSONDecoder().decode(ServerFile.self, from: responseData)
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

    private func uploadMultipart(_ path: String, fileData: Data, filename: String, parentID: String?) async throws -> ServerFile {
        let boundary = UUID().uuidString
        var request = URLRequest(url: URL(string: "\(baseURL)\(path)")!)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        addAuth(&request)

        var body = Data()
        if let parentID = parentID {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"parent_id\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(parentID)\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await execute(request)
        try checkResponse(response)
        return try JSONDecoder().decode(ServerFile.self, from: data)
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

struct ShareLink: Codable, Identifiable {
    let id: String
    let url: String
    let name: String?
    let notify_on_download: Bool
    let created_at: String
}

// MARK: - Chunked upload models

struct UploadSession: Codable {
    let uploadID: String
    let chunkSize: Int
    let totalChunks: Int

    enum CodingKeys: String, CodingKey {
        case uploadID = "upload_id"
        case chunkSize = "chunk_size"
        case totalChunks = "total_chunks"
    }
}

struct UploadStatus: Codable {
    let uploadID: String
    let totalChunks: Int
    let receivedChunks: [Int]
    let complete: Bool

    enum CodingKeys: String, CodingKey {
        case uploadID = "upload_id"
        case totalChunks = "total_chunks"
        case receivedChunks = "received_chunks"
        case complete
    }
}

struct ChunkedUploadResult: Codable {
    let id: String
    let name: String
    let size: Int64
    let contentHash: String

    enum CodingKeys: String, CodingKey {
        case id, name, size
        case contentHash = "content_hash"
    }
}

// MARK: - Delta sync models

struct BlockSignature: Codable {
    let index: Int
    let weakHash: UInt32
    let strongHash: String

    enum CodingKeys: String, CodingKey {
        case index
        case weakHash = "weak_hash"
        case strongHash = "strong_hash"
    }
}

struct BlocksResponse: Codable {
    let fileID: String
    let blockSize: Int
    let blocks: [BlockSignature]

    enum CodingKeys: String, CodingKey {
        case fileID = "file_id"
        case blockSize = "block_size"
        case blocks
    }
}

struct DeltaManifestBlock: Codable {
    let index: Int
    let offset: Int
}

struct DeltaManifest: Codable {
    let reuseBlocks: [Int]
    let newBlocks: [DeltaManifestBlock]

    enum CodingKeys: String, CodingKey {
        case reuseBlocks = "reuse_blocks"
        case newBlocks = "new_blocks"
    }
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

    enum CodingKeys: String, CodingKey {
        case id, name, size
        case relativePath = "relative_path"
        case contentHash = "content_hash"
        case isDir = "is_dir"
        case removedLocally = "removed_locally"
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
