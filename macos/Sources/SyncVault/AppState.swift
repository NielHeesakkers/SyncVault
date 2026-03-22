import SwiftUI
import Combine
import FileProvider

let appVersion = "1.7"

@MainActor
class AppState: ObservableObject {
    @Published var isConnected = false
    @Published var isSyncing = false
    @Published var lastError: String?
    @Published var recentActivity: [ActivityItem] = []
    @Published var syncTasks: [SyncTask] = []
    @Published var storageUsed: Int64 = 0
    @Published var storageTotal: Int64 = 0
    @Published var notifications: [AppNotification] = []
    @Published var unreadCount: Int = 0

    // Server config (persisted)
    @Published var serverURL: String = ""
    @Published var username: String = ""

    var menuBarIcon: String {
        if !isConnected { return "cloud.slash" }
        if isSyncing { return "arrow.triangle.2.circlepath.icloud" }
        return "checkmark.icloud"
    }

    private(set) var apiClient: APIClient?
    private var syncEngine: SyncEngine?
    private var syncTimer: Timer?
    private var notificationTimer: Timer?

    init() {
        loadConfig()
        // Try to auto-reconnect with saved credentials
        Task { await tryAutoConnect() }
    }

    // MARK: - Connection

    func connect(url: String, username: String, password: String) async throws {
        let client = APIClient(baseURL: url)
        try await client.login(username: username, password: password)
        self.apiClient = client
        self.serverURL = url
        self.username = username
        self.isConnected = true

        // Save password in Keychain for auto-reconnect
        KeychainHelper.save(key: "server_password", value: password)

        // Also save token to shared keychain for File Provider extension
        if let token = KeychainHelper.load(key: "access_token") {
            KeychainHelper.saveShared(key: "access_token", value: token)
        }
        // Save server URL to shared UserDefaults
        let sharedDefaults = UserDefaults(suiteName: "DE59N86W33.com.syncvault.shared")
        sharedDefaults?.set(url, forKey: "serverURL")

        saveConfig()

        // Start sync loop
        startSyncLoop()

        // Start notification polling
        startNotificationPolling()
    }

    func disconnect() {
        stopSyncLoop()
        stopNotificationPolling()
        apiClient = nil
        isConnected = false
        isSyncing = false
        notifications = []
        unreadCount = 0
        KeychainHelper.delete(key: "server_password")
    }

    private func tryAutoConnect() async {
        guard !serverURL.isEmpty, !username.isEmpty else { return }
        guard let password = KeychainHelper.load(key: "server_password") else { return }

        do {
            try await connect(url: serverURL, username: username, password: password)
        } catch {
            lastError = "Auto-connect failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Config Persistence

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

    // MARK: - Sync Task Management

    func addSyncTask(localPath: String, mode: SyncTask.SyncMode) async throws {
        guard let client = apiClient else { throw APIError.unauthorized }

        // Use local folder name as remote folder name
        let folderName = URL(fileURLWithPath: localPath).lastPathComponent
        let taskType = mode == .twoWay ? "sync" : "backup"

        // Create task on server (this creates the remote folder automatically)
        let body: [String: Any] = [
            "name": folderName,
            "type": taskType,
            "local_path": localPath
        ]
        let response: TaskResponse = try await client.createTask(body: body)

        // Save locally
        let task = SyncTask(
            localPath: localPath,
            remoteFolderID: response.folderID,
            remoteFolderName: folderName,
            mode: mode
        )
        syncTasks.append(task)
        saveConfig()
    }

    func deleteSyncTask(_ task: SyncTask) {
        syncTasks.removeAll { $0.id == task.id }
        saveConfig()
    }

    func updateSyncTask(_ task: SyncTask) {
        if let index = syncTasks.firstIndex(where: { $0.id == task.id }) {
            syncTasks[index] = task
            saveConfig()
        }
    }

    // MARK: - Sync Loop

    func startSyncLoop() {
        stopSyncLoop()
        // Run sync every 30 seconds
        syncTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.runSync()
            }
        }
        // Also run immediately
        Task { await runSync() }
    }

    func stopSyncLoop() {
        syncTimer?.invalidate()
        syncTimer = nil
    }

    // MARK: - Notification Polling

    func startNotificationPolling() {
        stopNotificationPolling()
        notificationTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.checkNotifications()
            }
        }
        // Also fetch immediately
        Task { await checkNotifications() }
    }

    func stopNotificationPolling() {
        notificationTimer?.invalidate()
        notificationTimer = nil
    }

    func checkNotifications() async {
        guard let client = apiClient, isConnected else { return }
        do {
            let response = try await client.getNotifications()
            notifications = response.notifications
            unreadCount = response.unread_count
        } catch {
            // Silently ignore notification fetch errors to avoid spamming the user
        }
    }

    // MARK: - Team Invite Actions

    func acceptTeamInvite(notificationId: String, teamId: String, teamName: String, localFolder: URL) async {
        guard let client = apiClient else { return }
        do {
            try await client.acceptNotification(id: notificationId)

            // Create a sync task pointing at the team folder on the server
            let task = SyncTask(
                localPath: localFolder.path,
                remoteFolderID: teamId,
                remoteFolderName: teamName,
                mode: .twoWay,
                isTeamFolder: true
            )
            syncTasks.append(task)
            saveConfig()

            // Refresh notifications
            await checkNotifications()
        } catch {
            lastError = "Failed to accept team invite: \(error.localizedDescription)"
        }
    }

    func declineTeamInvite(notificationId: String) async {
        guard let client = apiClient else { return }
        do {
            try await client.declineNotification(id: notificationId)
            await checkNotifications()
        } catch {
            lastError = "Failed to decline team invite: \(error.localizedDescription)"
        }
    }

    func runSync() async {
        guard let client = apiClient, isConnected else { return }
        guard !isSyncing else { return }

        isSyncing = true
        defer { isSyncing = false }

        for task in syncTasks where task.isEnabled {
            do {
                let dbPath = Self.configDirectory.appendingPathComponent("sync.db")
                let engine = try SyncEngine(apiClient: client, dbPath: dbPath)
                let result = try await engine.syncTask(task)

                // Add to recent activity
                if result.uploaded > 0 {
                    recentActivity.insert(ActivityItem(
                        filename: "\(result.uploaded) file(s)",
                        action: "uploaded",
                        timestamp: Date()
                    ), at: 0)
                }
                if result.downloaded > 0 {
                    recentActivity.insert(ActivityItem(
                        filename: "\(result.downloaded) file(s)",
                        action: "downloaded",
                        timestamp: Date()
                    ), at: 0)
                }

                // Keep only last 20 activity items
                if recentActivity.count > 20 {
                    recentActivity = Array(recentActivity.prefix(20))
                }
            } catch {
                lastError = "Sync error: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - On-Demand Sync (File Provider)

    func setupOnDemandSync(folderID: String) async throws {
        guard isConnected else { throw APIError.unauthorized }
        guard !folderID.isEmpty else { throw APIError.serverError(400) }

        let sharedDefaults = UserDefaults(suiteName: "DE59N86W33.com.syncvault.shared")!
        sharedDefaults.set(folderID, forKey: "onDemandFolderID")
        sharedDefaults.set(serverURL, forKey: "serverURL")

        if let token = KeychainHelper.load(key: "access_token") {
            KeychainHelper.saveShared(key: "access_token", value: token)
        }

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
    let action: String
    let timestamp: Date
}

struct TaskResponse: Codable {
    let id: String
    let name: String
    let type: String
    let folderID: String
    let folderName: String

    enum CodingKeys: String, CodingKey {
        case id, name, type
        case folderID = "folder_id"
        case folderName = "folder_name"
    }
}
