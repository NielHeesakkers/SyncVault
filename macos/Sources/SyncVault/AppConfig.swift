import Foundation

struct AppConfig: Codable {
    var serverURL: String
    var username: String
    var syncTasks: [SyncTask]
}
