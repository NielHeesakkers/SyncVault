import Foundation

struct ServerFile: Codable, Identifiable {
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

/// A file in the server trash. Same shape as ServerFile but with deletedAt
/// guaranteed non-nil. Used by TrashView for the in-app restore/permanent-
/// delete UI so users don't have to bounce to the web app to clean up.
typealias TrashedFile = ServerFile

/// One file as it existed at a given point in time. Returned by
/// GET /api/files/history?parent_id=&at=. The version_num + version_id
/// pinpoint which historical snapshot the entry represents.
struct FileAtTime: Codable, Identifiable {
    let id: String
    let name: String
    let isDir: Bool
    let size: Int64
    let versionNum: Int
    let versionID: String
    let contentHash: String?
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id, name, size
        case isDir = "is_dir"
        case versionNum = "version_num"
        case versionID = "version_id"
        case contentHash = "content_hash"
        case updatedAt = "updated_at"
    }
}

/// One snapshot in a file's history. Returned by GET /api/files/{id}/versions
/// and rendered by VersionDiffView's timeline.
struct FileVersion: Codable, Identifiable {
    let versionNum: Int
    let size: Int64
    let contentHash: String?
    let createdAt: String
    let createdBy: String?    // username

    var id: Int { versionNum }

    enum CodingKeys: String, CodingKey {
        case versionNum = "version_num"
        case size
        case contentHash = "content_hash"
        case createdAt = "created_at"
        case createdBy = "created_by"
    }
}

struct ChangesResponse: Codable {
    let changes: [ServerFile]
    let serverTime: String

    enum CodingKeys: String, CodingKey {
        case changes
        case serverTime = "server_time"
    }
}
