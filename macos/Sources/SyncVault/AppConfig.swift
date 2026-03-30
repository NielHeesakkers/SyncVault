import Foundation

struct AppConfig: Codable {
    var serverURL: String
    var username: String
    var syncTasks: [SyncTask]
    var lanURL: String?
    var externalURL: String?
}
