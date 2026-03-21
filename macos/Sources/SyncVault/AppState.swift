import SwiftUI
import Combine
import FileProvider

@MainActor
class AppState: ObservableObject {
    @Published var isConnected = false
    @Published var isSyncing = false
    @Published var lastError: String?
    @Published var recentActivity: [ActivityItem] = []
    @Published var syncTasks: [SyncTask] = []
    @Published var storageUsed: Int64 = 0
    @Published var storageTotal: Int64 = 0

    // Server config (persisted)
    @Published var serverURL: String = ""
    @Published var username: String = ""

    var menuBarIcon: String {
        if !isConnected { return "cloud.slash" }
        if isSyncing { return "arrow.triangle.2.circlepath.icloud" }
        return "checkmark.icloud"
    }

    private var apiClient: APIClient?
    private var syncEngine: SyncEngine?

    init() {
        loadConfig()
    }

    func connect(url: String, username: String, password: String) async throws {
        let client = APIClient(baseURL: url)
        try await client.login(username: username, password: password)
        self.apiClient = client
        self.serverURL = url
        self.username = username
        self.isConnected = true
        saveConfig()
    }

    func disconnect() {
        apiClient = nil
        isConnected = false
        isSyncing = false
    }

    func loadConfig() {
        let configURL = Self.configDirectory.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: configURL),
              let config = try? JSONDecoder().decode(AppConfig.self, from: data) else { return }
        serverURL = config.serverURL
        username = config.username
        syncTasks = config.syncTasks
    }

    func saveConfig() {
        let config = AppConfig(serverURL: serverURL, username: username, syncTasks: syncTasks)
        let configURL = Self.configDirectory.appendingPathComponent("config.json")
        try? FileManager.default.createDirectory(at: Self.configDirectory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(config).write(to: configURL)
    }

    static var configDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SyncVault")
    }

    // MARK: - On-Demand Sync (File Provider)

    func setupOnDemandSync(folderID: String) async throws {
        guard isConnected else { throw APIError.unauthorized }

        // Store folder ID and server URL in shared app group defaults
        SharedConfig.setOnDemandFolderID(folderID)
        SharedConfig.sharedDefaults.set(serverURL, forKey: "serverURL")

        // Store auth token in shared keychain for the extension to access
        if let token = KeychainHelper.load(key: "access_token") {
            KeychainHelper.saveShared(key: "access_token", value: token)
        }

        // Register the File Provider domain
        let domainIdentifier = NSFileProviderDomainIdentifier("com.syncvault.\(username)")
        let domain = NSFileProviderDomain(
            identifier: domainIdentifier,
            displayName: "SyncVault - \(username)"
        )

        try await NSFileProviderManager.add(domain)
    }

    func removeOnDemandSync() async throws {
        let domainIdentifier = NSFileProviderDomainIdentifier("com.syncvault.\(username)")
        let domain = NSFileProviderDomain(
            identifier: domainIdentifier,
            displayName: "SyncVault - \(username)"
        )
        try await NSFileProviderManager.remove(domain)
    }
}

struct ActivityItem: Identifiable {
    let id = UUID()
    let filename: String
    let action: String // "uploaded", "downloaded", "deleted"
    let timestamp: Date
}
