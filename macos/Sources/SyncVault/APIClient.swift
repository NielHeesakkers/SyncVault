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
}

enum APIError: Error, LocalizedError {
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
