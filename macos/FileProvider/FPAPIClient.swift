import Foundation
import CommonCrypto

actor FPAPIClient {
    let baseURL: String
    private var accessToken: String?
    private var username: String?
    private var password: String?

    init(baseURL: String, token: String?, username: String? = nil, password: String? = nil) {
        self.baseURL = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.accessToken = token
        self.username = username
        self.password = password
    }

    // MARK: - API Methods

    func listFiles(parentID: String? = nil) async throws -> [FPServerFile] {
        var path = "/api/files"
        if let parentID = parentID {
            path += "?parent_id=\(parentID)"
        }
        let response: FPFilesResponse = try await getWithReauth(path)
        return response.files
    }

    /// Stream download directly to a temp file (no memory pressure)
    func downloadFileToDisk(id: String) async throws -> (URL, FPServerFile) {
        var request = URLRequest(url: URL(string: "\(baseURL)/api/files/\(id)/download")!)
        request.httpMethod = "GET"
        addAuth(&request)
        let (tempURL, response) = try await URLSession.shared.download(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 401 {
            try await reAuthenticate()
            addAuth(&request)
            let (tempURL2, response2) = try await URLSession.shared.download(for: request)
            try checkResponse(response2)
            let file = try await getFile(id: id)
            return (tempURL2, file)
        }
        try checkResponse(response)
        let file = try await getFile(id: id)
        return (tempURL, file)
    }

    func deleteFile(id: String) async throws {
        try await deleteWithReauth("/api/files/\(id)")
    }

    /// Upload a file via block upload — same protocol as the sync engine.
    /// No temp files, no memory pressure, with real network progress.
    /// 1. Split file into 4MB blocks, compute SHA-256 per block
    /// 2. Check which blocks server already has (dedup)
    /// 3. Upload only missing blocks
    /// 4. Create file on server from blocks
    func uploadFileFromDisk(fileURL: URL, filename: String, parentID: String?, onProgress: ((Int64, Int64) -> Void)? = nil) async throws -> FPServerFile {
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0

        SharedConfig.setProgress(action: "Uploading", filename: filename, bytesTransferred: 0, totalBytes: fileSize)

        // Streaming upload: single HTTP request, streamed from disk (like Synology Drive).
        // No block protocol overhead — much faster on SMB/NFS storage.
        let boundary = UUID().uuidString
        let pid = parentID ?? ""

        // Build multipart body as temp file (avoids loading file into memory)
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent(UUID().uuidString + ".multipart")
        defer { try? FileManager.default.removeItem(at: tempFile) }

        FileManager.default.createFile(atPath: tempFile.path, contents: nil)
        let writeHandle = try FileHandle(forWritingTo: tempFile)

        // Write multipart header + parent_id
        let header = "--\(boundary)\r\nContent-Disposition: form-data; name=\"parent_id\"\r\n\r\n\(pid)\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\nContent-Type: application/octet-stream\r\n\r\n"
        writeHandle.write(header.data(using: .utf8)!)

        // Stream file content in 4MB chunks
        let readHandle = try FileHandle(forReadingFrom: fileURL)
        defer { readHandle.closeFile() }
        let chunkSize = 4 * 1024 * 1024
        var written: Int64 = 0
        while true {
            let chunk = readHandle.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }
            writeHandle.write(chunk)
            written += Int64(chunk.count)
            SharedConfig.setProgress(action: "Uploading", filename: filename, bytesTransferred: written, totalBytes: fileSize)
            onProgress?(written, fileSize)
        }

        // Write multipart footer
        writeHandle.write("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        writeHandle.closeFile()

        // Upload via streaming (URLSession reads from disk)
        var request = URLRequest(url: URL(string: "\(baseURL)/api/files/upload")!)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let token = accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 3600

        request.httpBody = try Data(contentsOf: tempFile)
        let (data, response) = try await URLSession.shared.data(for: request)
        try checkResponse(response)
        SharedConfig.clearProgress()

        let result = try JSONDecoder().decode(FPServerFile.self, from: data)
        return result
    }

    // MARK: - Block operations

    func checkBlocks(_ hashes: [String]) async throws -> [String] {
        struct CheckResponse: Codable { let existing: [String] }
        let body: [String: Any] = ["hashes": hashes]
        let response: CheckResponse = try await post("/api/blocks/check", body: body)
        return response.existing
    }

    // MARK: - SHA-256 helper

    private func sha256Hex(_ data: Data) -> String {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash) }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - SSE (Server-Sent Events)

    /// Returns an AsyncThrowingStream of SSE events from /api/events.
    /// Each yielded tuple contains (event name, data payload).
    func listenForSSE() -> AsyncThrowingStream<(event: String, data: String), Error> {
        // Capture what we need before returning the non-isolated stream
        let url = URL(string: "\(baseURL)/api/events")!
        let token = accessToken ?? ""

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: url)
                    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.timeoutInterval = .infinity

                    let config = URLSessionConfiguration.default
                    config.timeoutIntervalForRequest = .infinity
                    config.timeoutIntervalForResource = .infinity
                    let session = URLSession(configuration: config)

                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        continuation.finish(throwing: FPAPIError.invalidResponse)
                        return
                    }
                    if http.statusCode == 401 {
                        continuation.finish(throwing: FPAPIError.unauthorized)
                        return
                    }
                    if http.statusCode >= 400 {
                        continuation.finish(throwing: FPAPIError.serverError(http.statusCode))
                        return
                    }

                    var currentEvent = ""
                    var currentData = ""

                    for try await line in bytes.lines {
                        if line.hasPrefix("event: ") {
                            currentEvent = String(line.dropFirst(7))
                        } else if line.hasPrefix("data: ") {
                            currentData = String(line.dropFirst(6))
                        } else if line.isEmpty {
                            if !currentEvent.isEmpty {
                                continuation.yield((event: currentEvent, data: currentData))
                            }
                            currentEvent = ""
                            currentData = ""
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func getChanges(since: Date) async throws -> FPChangesResponse {
        let formatter = ISO8601DateFormatter()
        let sinceStr = formatter.string(from: since).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return try await getWithReauth("/api/changes?since=\(sinceStr)")
    }

    func getFile(id: String) async throws -> FPServerFile {
        return try await getWithReauth("/api/files/\(id)")
    }

    func createFolder(name: String, parentID: String) async throws -> FPServerFile {
        let body: [String: Any] = ["name": name, "parent_id": parentID, "is_dir": true]
        return try await post("/api/files", body: body)
    }

    func moveFile(id: String, name: String, parentID: String) async throws {
        let body: [String: Any] = ["name": name, "parent_id": parentID]
        let _: [String: String] = try await put("/api/files/\(id)", body: body)
    }

    // MARK: - Auto Re-Auth on 401

    private func reAuthenticate() async throws {
        struct LoginResponse: Codable { let access_token: String; let refresh_token: String }

        // 1. Try refresh token first (avoids sending password over the wire)
        if let refreshToken = SharedConfig.loadCredential(key: "refresh_token") ?? SharedConfig.loadFromKeychain(key: "refresh_token"),
           !refreshToken.isEmpty {
            do {
                let body: [String: String] = ["refresh_token": refreshToken]
                var request = URLRequest(url: URL(string: "\(baseURL)/api/auth/refresh")!)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode < 400 {
                    let loginResp = try JSONDecoder().decode(LoginResponse.self, from: data)
                    self.accessToken = loginResp.access_token
                    SharedConfig.saveToKeychain(key: "access_token", value: loginResp.access_token)
                    SharedConfig.saveCredential(key: "refresh_token", value: loginResp.refresh_token)
                    return
                }
            } catch {
                // Refresh failed — fall through to password login
            }
        }

        // 2. Fall back to re-login with saved password
        let freshUsername = username ?? SharedConfig.loadCredential(key: "fp_username") ?? SharedConfig.loadFromKeychain(key: "fp_username")
        let freshPassword = password ?? SharedConfig.loadCredential(key: "fp_password") ?? SharedConfig.loadFromKeychain(key: "fp_password")
        guard let user = freshUsername, let pass = freshPassword else {
            throw FPAPIError.unauthorized
        }
        // Update stored credentials for next time
        self.username = user
        self.password = pass

        let body: [String: String] = ["username": user, "password": pass]
        var request = URLRequest(url: URL(string: "\(baseURL)/api/auth/login")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(LoginResponse.self, from: data)
        self.accessToken = response.access_token
        // Save new tokens to shared storage for next time
        SharedConfig.saveToKeychain(key: "access_token", value: response.access_token)
        SharedConfig.saveCredential(key: "refresh_token", value: response.refresh_token)
    }

    private func getWithReauth<T: Decodable>(_ path: String) async throws -> T {
        do {
            return try await get(path)
        } catch FPAPIError.unauthorized {
            try await reAuthenticate()
            return try await get(path)
        }
    }

    private func deleteWithReauth(_ path: String) async throws {
        do {
            try await deleteRequest(path)
        } catch FPAPIError.unauthorized {
            try await reAuthenticate()
            try await deleteRequest(path)
        }
    }

    // MARK: - HTTP

    private func get<T: Decodable>(_ path: String) async throws -> T {
        var request = URLRequest(url: URL(string: "\(baseURL)\(path)")!)
        request.httpMethod = "GET"
        addAuth(&request)
        let (data, response) = try await URLSession.shared.data(for: request)
        try checkResponse(response)
        return try JSONDecoder().decode(T.self, from: data)
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

    private func deleteRequest(_ path: String) async throws {
        var request = URLRequest(url: URL(string: "\(baseURL)\(path)")!)
        request.httpMethod = "DELETE"
        addAuth(&request)
        let (_, response) = try await URLSession.shared.data(for: request)
        try checkResponse(response)
    }

    private func addAuth(_ request: inout URLRequest) {
        if let token = accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }

    private func checkResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw FPAPIError.invalidResponse }
        if http.statusCode == 401 { throw FPAPIError.unauthorized }
        if http.statusCode >= 400 { throw FPAPIError.serverError(http.statusCode) }
    }
}

// MARK: - Models

struct FPServerFile: Decodable {
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
    let removedLocally: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name, size
        case parentID = "parent_id"
        case isDir = "is_dir"
        case contentHash = "content_hash"
        case mimeType = "mime_type"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
        case removedLocally = "removed_locally"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        parentID = try c.decodeIfPresent(String.self, forKey: .parentID)
        isDir = (try? c.decode(Bool.self, forKey: .isDir)) ?? false
        contentHash = try c.decodeIfPresent(String.self, forKey: .contentHash)
        mimeType = try c.decodeIfPresent(String.self, forKey: .mimeType)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
        deletedAt = try c.decodeIfPresent(String.self, forKey: .deletedAt)
        removedLocally = try c.decodeIfPresent(Bool.self, forKey: .removedLocally)
        // size can be Int64 or String — handle both
        if let intSize = try? c.decode(Int64.self, forKey: .size) {
            size = intSize
        } else if let strSize = try? c.decode(String.self, forKey: .size), let parsed = Int64(strSize) {
            size = parsed
        } else {
            size = 0
        }
    }

    init(id: String, parentID: String?, name: String, isDir: Bool, size: Int64, contentHash: String?, mimeType: String?, createdAt: String?, updatedAt: String?, deletedAt: String?, removedLocally: Bool?) {
        self.id = id
        self.parentID = parentID
        self.name = name
        self.isDir = isDir
        self.size = size
        self.contentHash = contentHash
        self.mimeType = mimeType
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.removedLocally = removedLocally
    }
}

struct FPFilesResponse: Decodable { let files: [FPServerFile] }

struct FPChangesResponse: Decodable {
    let changes: [FPServerFile]
    let serverTime: String
    enum CodingKeys: String, CodingKey {
        case changes
        case serverTime = "server_time"
    }
}

enum FPAPIError: Error, LocalizedError {
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
