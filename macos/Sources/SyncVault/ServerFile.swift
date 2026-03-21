import Foundation

struct ServerFile: Codable, Identifiable {
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

struct FilesResponse: Codable {
    let files: [ServerFile]
}

struct LoginResponse: Codable {
    let accessToken: String
    let refreshToken: String
    let user: UserInfo

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case user
    }
}

struct UserInfo: Codable {
    let id: String
    let username: String
    let email: String
    let role: String
}

struct ChangesResponse: Codable {
    let changes: [ServerFile]
    let serverTime: String

    enum CodingKeys: String, CodingKey {
        case changes
        case serverTime = "server_time"
    }
}
