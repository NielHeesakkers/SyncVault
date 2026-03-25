import Foundation

actor APIClient {
    let baseURL: String
    private var accessToken: String?
    private var refreshToken: String?

    init(baseURL: String) {
        self.baseURL = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

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

    func getChanges(since: Date) async throws -> ChangesResponse {
        let formatter = ISO8601DateFormatter()
        let sinceStr = formatter.string(from: since)
        return try await get("/api/changes?since=\(sinceStr)")
    }

    func healthCheck() async throws -> Bool {
        let _: [String: String] = try await get("/api/health")
        return true
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

        let (responseData, response) = try await URLSession.shared.data(for: request)
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
        return try await post("/api/files", body: body)
    }

    func moveFile(id: String, name: String, parentID: String) async throws {
        let body: [String: Any] = ["name": name, "parent_id": parentID]
        let _: [String: String] = try await put("/api/files/\(id)", body: body)
    }

    // MARK: - Private HTTP methods

    private func get<T: Decodable>(_ path: String) async throws -> T {
        var request = URLRequest(url: URL(string: "\(baseURL)\(path)")!)
        request.httpMethod = "GET"
        addAuth(&request)
        let (data, response) = try await URLSession.shared.data(for: request)
        try checkResponse(response)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func getData(_ path: String) async throws -> Data {
        var request = URLRequest(url: URL(string: "\(baseURL)\(path)")!)
        request.httpMethod = "GET"
        addAuth(&request)
        let (data, response) = try await URLSession.shared.data(for: request)
        try checkResponse(response)
        return data
    }

    private func post<T: Decodable>(_ path: String, body: Any) async throws -> T {
        var request = URLRequest(url: URL(string: "\(baseURL)\(path)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        addAuth(&request)
        let (data, response) = try await URLSession.shared.data(for: request)
        try checkResponse(response)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func delete(_ path: String) async throws {
        var request = URLRequest(url: URL(string: "\(baseURL)\(path)")!)
        request.httpMethod = "DELETE"
        addAuth(&request)
        let (_, response) = try await URLSession.shared.data(for: request)
        try checkResponse(response)
    }

    private func put<T: Decodable>(_ path: String, body: Any) async throws -> T {
        var request = URLRequest(url: URL(string: "\(baseURL)\(path)")!)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        addAuth(&request)
        let (data, response) = try await URLSession.shared.data(for: request)
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

        let (data, response) = try await URLSession.shared.data(for: request)
        try checkResponse(response)
        return try JSONDecoder().decode(ServerFile.self, from: data)
    }

    /// Upload a file from disk without loading it into memory.
    /// Writes a multipart body to a temp file, then uses URLSession.upload(for:fromFile:).
    func uploadFileFromDisk(fileURL: URL, filename: String, parentID: String?) async throws -> ServerFile {
        let boundary = UUID().uuidString
        var request = URLRequest(url: URL(string: "\(baseURL)/api/files/upload")!)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        addAuth(&request)

        // Write multipart body to a temp file
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("upload-\(UUID().uuidString).multipart")
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        let tempHandle = try FileHandle(forWritingTo: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        func writeString(_ s: String) { tempHandle.write(s.data(using: .utf8)!) }

        // parent_id field
        if let parentID = parentID {
            writeString("--\(boundary)\r\n")
            writeString("Content-Disposition: form-data; name=\"parent_id\"\r\n\r\n")
            writeString("\(parentID)\r\n")
        }

        // file field header
        writeString("--\(boundary)\r\n")
        writeString("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        writeString("Content-Type: application/octet-stream\r\n\r\n")

        // Stream file content in chunks
        let sourceHandle = try FileHandle(forReadingFrom: fileURL)
        let chunkSize = 256 * 1024 * 1024 // 256MB
        while autoreleasepool(invoking: {
            let chunk = sourceHandle.readData(ofLength: chunkSize)
            if chunk.isEmpty { return false }
            tempHandle.write(chunk)
            return true
        }) {}
        sourceHandle.closeFile()

        // closing boundary
        writeString("\r\n--\(boundary)--\r\n")
        tempHandle.closeFile()

        // Upload from file (URLSession streams from disk, not memory)
        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: tempURL)
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

// Used for POST endpoints that return an empty or minimal body
private struct EmptyResponse: Codable {}

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
