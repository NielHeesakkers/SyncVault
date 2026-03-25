import SwiftUI
import Combine
import FileProvider
import os

private let logger = Logger(subsystem: "com.syncvault.app", category: "AppState")

let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.1"

@MainActor
class AppState: ObservableObject {
    @Published var isConnected = false
    @Published var isSyncing = false
    @Published var syncProgress: SyncProgress?
    @Published var syncQueue: [String] = []
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
    private var fileWatchers: [UUID: FileWatcher] = [:]  // per sync task

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

        // Save credentials in Keychain for auto-reconnect and re-auth
        KeychainHelper.save(key: "server_password", value: password)
        KeychainHelper.save(key: "saved_username", value: username)

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

    // MARK: - Security-Scoped Bookmarks

    func saveBookmark(for url: URL) {
        do {
            let bookmarkData = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            var bookmarks = loadBookmarks()
            bookmarks[url.path] = bookmarkData
            let bookmarkURL = Self.configDirectory.appendingPathComponent("bookmarks.plist")
            try (bookmarks as NSDictionary).write(to: bookmarkURL)
            logger.info("Saved bookmark for \(url.path)")
        } catch {
            logger.error("Failed to save bookmark: \(error)")
        }
    }

    func resolveBookmark(for path: String) -> URL? {
        let bookmarks = loadBookmarks()
        guard let data = bookmarks[path] else { return nil }
        var isStale = false
        do {
            let url = try URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)
            if url.startAccessingSecurityScopedResource() {
                if isStale {
                    saveBookmark(for: url)
                }
                return url
            }
        } catch {
            logger.error("Failed to resolve bookmark: \(error)")
        }
        return nil
    }

    private func loadBookmarks() -> [String: Data] {
        let bookmarkURL = Self.configDirectory.appendingPathComponent("bookmarks.plist")
        guard let dict = NSDictionary(contentsOf: bookmarkURL) as? [String: Data] else { return [:] }
        return dict
    }

    // MARK: - Sync Task Management

    func addSyncTask(localPath: String, mode: SyncTask.SyncMode) async throws {
        guard let client = apiClient else { throw APIError.unauthorized }

        // Save security-scoped bookmark for persistent access
        let url = URL(fileURLWithPath: localPath)
        saveBookmark(for: url)

        // Use local folder name as remote folder name
        let folderName = url.lastPathComponent
        let taskType: String
        switch mode {
        case .twoWay: taskType = "sync"
        case .uploadOnly: taskType = "backup"
        case .onDemand: taskType = "ondemand"
        }

        // Create task on server (this creates the remote folder automatically)
        let body: [String: Any] = [
            "name": folderName,
            "type": taskType,
            "local_path": localPath
        ]
        let response: TaskResponse = try await client.createTask(body: body)

        // Save locally
        var task = SyncTask(
            localPath: localPath,
            remoteFolderID: response.folderID,
            remoteFolderName: folderName,
            mode: mode
        )
        task.serverTaskID = response.id
        syncTasks.append(task)
        saveConfig()

        // For on-demand mode, register the File Provider domain
        if mode == .onDemand {
            try await setupOnDemandSync(folderID: response.folderID)
        }
    }

    func deleteSyncTask(_ task: SyncTask) {
        // Delete on server first
        if let serverID = task.serverTaskID, let client = apiClient {
            Task {
                try? await client.deleteTask(id: serverID)
            }
        }
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

        // Start file watchers for each sync task
        for task in syncTasks where task.isEnabled && task.mode != .onDemand {
            let watcher = FileWatcher(path: task.localPath)
            watcher.start()
            fileWatchers[task.id] = watcher
        }

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
        // Stop all file watchers
        for (_, watcher) in fileWatchers {
            watcher.stop()
        }
        fileWatchers.removeAll()
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

            // Save security-scoped bookmark for persistent access
            saveBookmark(for: localFolder)

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
        guard let client = apiClient, isConnected else {
            logger.info(" Not connected, skipping")
            return
        }
        guard !isSyncing else {
            logger.info(" Already syncing, skipping")
            return
        }

        isSyncing = true
        syncProgress = nil
        defer {
            isSyncing = false
            syncProgress = nil
        }

        for task in syncTasks where task.isEnabled && task.mode != .onDemand {
            logger.info("Starting task: \(task.remoteFolderName) (remote: \(task.remoteFolderID), local: \(task.localPath), mode: \(task.mode.rawValue))")

            // Resolve security-scoped bookmark for folder access
            let resolvedURL = resolveBookmark(for: task.localPath)
            defer { resolvedURL?.stopAccessingSecurityScopedResource() }

            if resolvedURL == nil {
                logger.warning("No bookmark for \(task.localPath) — cannot access folder")
                lastError = "Cannot access \(URL(fileURLWithPath: task.localPath).lastPathComponent) — re-select folder in Settings"
                continue
            }

            do {
                let dbPath = Self.configDirectory.appendingPathComponent("sync.db")
                let engine = try SyncEngine(apiClient: client, dbPath: dbPath)

                // Get changed paths from FSEvents watcher (nil = full scan needed)
                let changedPaths = fileWatchers[task.id]?.consumeChangedPaths()

                let result = try await engine.syncTask(task, changedPaths: changedPaths) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.syncProgress = progress
                        self?.syncQueue = progress.pendingFiles
                    }
                }

                logger.info(" Result: \(result.uploaded) up, \(result.downloaded) down, \(result.deleted) del, \(result.conflicts) conflicts, \(result.errors) errors")

                // Add individual file activity
                for item in result.fileActivity {
                    recentActivity.insert(item, at: 0)
                }

                // Keep only last 20 activity items
                if recentActivity.count > 20 {
                    recentActivity = Array(recentActivity.prefix(20))
                }
            } catch let error as APIError where error == .unauthorized {
                logger.info(" Token expired, re-authenticating...")
                if await client.reAuthenticate() {
                    logger.info(" Re-authenticated, will retry on next cycle")
                } else {
                    logger.error(" Re-authentication failed")
                    lastError = "Session expired — please reconnect"
                    isConnected = false
                }
                break
            } catch {
                logger.info(" Error: \(error)")
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
