import Foundation

struct SyncTask: Codable, Identifiable {
    let id: UUID
    var serverTaskID: String?  // ID on the server for delete/update
    var localPath: String
    var remoteFolderID: String
    var remoteFolderName: String
    var mode: SyncMode
    var excludePatterns: [String]
    var intervalSeconds: Int  // 0 = continuous, -1 = manual
    var isEnabled: Bool
    var isTeamFolder: Bool
    var initialSyncDirection: String?  // "download" or "upload", consumed after first sync

    enum SyncMode: String, Codable, CaseIterable {
        case twoWay = "two_way"
        case uploadOnly = "upload_only"
        case onDemand = "on_demand"

        var displayName: String {
            switch self {
            case .twoWay: return "Two-way Sync"
            case .uploadOnly: return "Upload Only (Backup)"
            case .onDemand: return "On-demand"
            }
        }
    }

    init(localPath: String, remoteFolderID: String, remoteFolderName: String, mode: SyncMode = .twoWay, isTeamFolder: Bool = false) {
        self.id = UUID()
        self.localPath = localPath
        self.remoteFolderID = remoteFolderID
        self.remoteFolderName = remoteFolderName
        self.mode = mode
        self.excludePatterns = [
            ".DS_Store", "*.tmp", "Thumbs.db",
            "node_modules", ".git", ".svn",
            "__pycache__", "*.pyc",
            ".build", "DerivedData", "build",
            ".cache", ".npm", ".yarn",
            "Pods", ".cocoapods",
            "venv", ".venv", "env",
        ]
        self.intervalSeconds = 30
        self.isEnabled = true
        self.isTeamFolder = isTeamFolder
    }
}
