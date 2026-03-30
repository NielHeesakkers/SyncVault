import Foundation

actor FPAPIClient {
    let baseURL: String
    private var accessToken: String?
    private let username: String?
    private let password: String?

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

    func downloadFile(id: String) async throws -> Data {
        return try await getDataWithReauth("/api/files/\(id)/download")
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

    func uploadFile(data: Data, filename: String, parentID: String?) async throws -> FPServerFile {
        return try await uploadMultipart("/api/files/upload", fileData: data, filename: filename, parentID: parentID)
    }

    func deleteFile(id: String) async throws {
        try await deleteWithReauth("/api/files/\(id)")
    }

    func getChanges(since: Date) async throws -> FPChangesResponse {
        let formatter = ISO8601DateFormatter()
        let sinceStr = formatter.string(from: since).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return try await getWithReauth("/api/changes?since=\(sinceStr)")
    }

    func getFile(id: String) async throws -> FPServerFile {
        let files: FPFilesResponse = try await getWithReauth("/api/files")
        guard let file = files.files.first(where: { $0.id == id }) else {
            throw FPAPIError.serverError(404)
        }
        return file
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
        guard let username = username, let password = password else {
            throw FPAPIError.unauthorized
        }
        struct LoginResponse: Codable { let access_token: String; let refresh_token: String }
        let body: [String: String] = ["username": username, "password": password]
        var request = URLRequest(url: URL(string: "\(baseURL)/api/auth/login")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(LoginResponse.self, from: data)
        self.accessToken = response.access_token
        // Save new token to shared keychain for next time
        SharedConfig.saveToKeychain(key: "access_token", value: response.access_token)
    }

    private func getWithReauth<T: Decodable>(_ path: String) async throws -> T {
        do {
            return try await get(path)
        } catch FPAPIError.unauthorized {
            try await reAuthenticate()
            return try await get(path)
        }
    }

    private func getDataWithReauth(_ path: String) async throws -> Data {
        do {
            return try await getData(path)
        } catch FPAPIError.unauthorized {
            try await reAuthenticate()
            return try await getData(path)
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

    private func uploadMultipart(_ path: String, fileData: Data, filename: String, parentID: String?) async throws -> FPServerFile {
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
        return try JSONDecoder().decode(FPServerFile.self, from: data)
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

struct FPServerFile: Codable {
    let id: String
    let parentID: String?
    let name: String
    let isDir: Bool
    let size: Int64
    let contentHash: String?
    let mimeType: String?
    let createdAt: String
    let updatedAt: String
    let deletedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, name, size
        case parentID = "parent_id"
        case isDir = "is_dir"
        case contentHash = "content_hash"
        case mimeType = "mime_type"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }
}

struct FPFilesResponse: Codable { let files: [FPServerFile] }

struct FPChangesResponse: Codable {
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
