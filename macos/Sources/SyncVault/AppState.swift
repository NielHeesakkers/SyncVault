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
    private var syncPending = false
    @Published var isPaused = false
    @Published var syncProgress: SyncProgress?
    @Published var fpProgress: String?  // FileProvider on-demand progress (e.g. "Uploading photo.jpg")
    @Published var fpSpeed: Double = 0  // bytes per second
    private var fpLastBytes: Int64 = 0
    private var fpLastTime: Date?
    @Published var syncQueue: [String] = []
    @Published var speedHistory: [Double] = []  // last 60 samples (10 min at 10s intervals)
    private var speedTimer: Timer?
    private var fpProgressTimer: Timer?
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

    // LAN/External URL auto-detection
    @Published var lanURL: String = ""       // e.g. "http://192.168.1.2:4282"
    @Published var externalURL: String = ""  // e.g. "https://sync.heesakkers.com"

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
    private var syncDatabase: SyncDatabase?
    private var wakeObserver: NSObjectProtocol?

    init() {
        loadConfig()
        // Initialize sync database at app start so known state persists
        initSyncDatabase()
        // Try to auto-reconnect with saved credentials
        Task { await tryAutoConnect() }
        // Re-authenticate after wake from sleep
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                logger.info("Wake from sleep — re-authenticating")
                self.lastError = nil
                if self.isConnected, let client = self.apiClient {
                    if await client.reAuthenticate() {
                        logger.info("Re-authenticated after wake")
                    } else if let password = KeychainHelper.load(key: "server_password") {
                        do {
                            try await client.login(username: self.username, password: password)
                            logger.info("Re-logged in after wake")
                        } catch {
                            logger.error("Re-login after wake failed: \(error)")
                        }
                    }
                } else if !self.isConnected {
                    await self.tryAutoConnect()
                }
            }
        }
    }

    deinit {
        syncTimer?.invalidate()
        speedTimer?.invalidate()
        notificationTimer?.invalidate()
        if let observer = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    /// Shared app group container URL — accessible by FinderSync extension
    static var sharedContainerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "DE59N86W33.com.syncvault.shared")
    }

    private func initSyncDatabase() {
        // Use shared app group container so FinderSync can read the database for badges
        let containerURL = Self.sharedContainerURL ?? Self.configDirectory
        let dbPath = containerURL.appendingPathComponent("sync.db")
        do {
            try FileManager.default.createDirectory(at: containerURL, withIntermediateDirectories: true)

            // Migrate: if old database exists in configDirectory, move it
            let oldPath = Self.configDirectory.appendingPathComponent("sync.db")
            if FileManager.default.fileExists(atPath: oldPath.path) && !FileManager.default.fileExists(atPath: dbPath.path) {
                try? FileManager.default.moveItem(at: oldPath, to: dbPath)
                logger.info("Migrated sync database to shared container")
            }

            if !FileManager.default.fileExists(atPath: dbPath.path) {
                FileManager.default.createFile(atPath: dbPath.path, contents: nil)
            }
            syncDatabase = try SyncDatabase(path: dbPath.path)
            _ = try? syncDatabase?.getStates(taskID: "__init__")
            logger.info("Sync database initialized at \(dbPath.path)")
        } catch {
            logger.error("Failed to initialize sync database: \(error)")
        }
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
        lanURL = config.lanURL ?? ""
        externalURL = config.externalURL ?? ""
    }

    func saveConfig() {
        let config = AppConfig(serverURL: serverURL, username: username, syncTasks: syncTasks, lanURL: lanURL, externalURL: externalURL)
        let configURL = Self.configDirectory.appendingPathComponent("config.json")
        try? FileManager.default.createDirectory(at: Self.configDirectory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(config).write(to: configURL)

        // Update monitored paths for Finder Sync Extension
        let paths = syncTasks.filter { $0.mode != .onDemand }.map { $0.localPath }
        let sharedDefaults = UserDefaults(suiteName: "DE59N86W33.com.syncvault.shared")
        sharedDefaults?.set(paths, forKey: "monitoredPaths")

        // Write task mapping: localPath → taskID (for FinderSync badges)
        var mapping: [String: String] = [:]
        for task in syncTasks where task.isEnabled && task.mode != .onDemand {
            mapping[task.localPath] = task.id.uuidString
        }
        if let jsonData = try? JSONSerialization.data(withJSONObject: mapping),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            sharedDefaults?.set(jsonString, forKey: "syncTaskMapping")
        }

        // Notify FinderSync extension that paths changed
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("com.syncvault.monitoredPathsChanged"),
            object: nil
        )
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
        try await addSyncTask(localPath: localPath, mode: mode, remoteFolderID: nil, remoteFolderName: nil, initialDirection: nil)
    }

    func addSyncTask(localPath: String, mode: SyncTask.SyncMode, remoteFolderID: String?, remoteFolderName: String?, initialDirection: String?) async throws {
        guard let client = apiClient else { throw APIError.unauthorized }

        // Save security-scoped bookmark for persistent access
        let url = URL(fileURLWithPath: localPath)
        saveBookmark(for: url)

        let folderName = remoteFolderName ?? url.lastPathComponent
        let taskType: String
        switch mode {
        case .twoWay: taskType = "sync"
        case .uploadOnly: taskType = "backup"
        case .onDemand: taskType = "ondemand"
        }

        // Create task on server
        var body: [String: Any] = [
            "name": folderName,
            "type": taskType,
            "local_path": localPath
        ]
        if let folderID = remoteFolderID {
            body["folder_id"] = folderID
        }
        let response: TaskResponse = try await client.createTask(body: body)

        // Save locally
        var task = SyncTask(
            localPath: localPath,
            remoteFolderID: response.folderID,
            remoteFolderName: response.folderName.isEmpty ? folderName : response.folderName,
            mode: mode
        )
        task.serverTaskID = response.id
        task.initialSyncDirection = initialDirection
        syncTasks.append(task)
        saveConfig()

        // Try to restore sync state from server (new-Mac scenario)
        let deviceID = getDeviceID()
        if let db = syncDatabase {
            let engine = SyncEngine(apiClient: client, db: db)
            if let remoteStates = try? await client.getSyncStates(deviceID: deviceID, taskName: folderName) {
                try? await engine.restoreSyncStates(taskID: task.id.uuidString, states: remoteStates)
                logger.info("Restored \(remoteStates.count) sync states from server for task \(folderName)")
            }
        }

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

        // Poll FileProvider on-demand progress every 0.5 seconds
        fpProgressTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkFileProviderProgress()
            }
        }

        // Start file watchers for each sync task
        for task in syncTasks where task.isEnabled && task.mode != .onDemand {
            let watcher = FileWatcher(path: task.localPath)
            watcher.onChange = { [weak self] in
                self?.onFileChanged()
            }
            watcher.start()
            fileWatchers[task.id] = watcher
        }

        // 60-second fallback timer (in case FSEvents misses something, or errors need retry)
        syncTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.runSync()
            }
        }
        // Also run immediately
        Task { await runSync() }
    }

    /// Called by FileWatcher when changes are detected (already debounced 1s).
    func onFileChanged() {
        Task { await runSync() }
    }

    func stopSyncLoop() {
        syncTimer?.invalidate()
        syncTimer = nil
        fpProgressTimer?.invalidate()
        fpProgressTimer = nil
        fpProgress = nil
        // Stop all file watchers
        for (_, watcher) in fileWatchers {
            watcher.stop()
        }
        fileWatchers.removeAll()
    }

    // MARK: - Speed Tracking

    private func startSpeedTracking() {
        speedTimer?.invalidate()
        // Record initial sample immediately
        recordSpeedSample()
        speedTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.recordSpeedSample()
            }
        }
    }

    private func stopSpeedTracking() {
        speedTimer?.invalidate()
        speedTimer = nil
        // Don't clear speedHistory — keep it for display until next sync starts
    }

    /// Record a speed sample from the current sync progress and check FileProvider progress.
    func recordSpeedSample() {
        let speed = syncProgress?.bytesPerSecond ?? 0
        speedHistory.append(speed)
        if speedHistory.count > 60 {
            speedHistory.removeFirst(speedHistory.count - 60)
        }
        // Poll FileProvider on-demand progress from shared UserDefaults
        checkFileProviderProgress()
    }

    private func checkFileProviderProgress() {
        let defaults = UserDefaults(suiteName: "DE59N86W33.com.syncvault.shared")

        // Import recent files from FileProvider extension
        if let recent = defaults?.array(forKey: "fp_recent_files") as? [[String: String]], !recent.isEmpty {
            for entry in recent {
                guard let filename = entry["filename"], let action = entry["action"] else { continue }
                let alreadyTracked = recentActivity.contains { $0.filename == filename && $0.action == action }
                if !alreadyTracked {
                    let ts = Double(entry["timestamp"] ?? "0") ?? 0
                    let item = ActivityItem(filename: filename, action: action, timestamp: Date(timeIntervalSince1970: ts))
                    recentActivity.insert(item, at: 0)
                }
            }
            if recentActivity.count > 20 { recentActivity = Array(recentActivity.prefix(20)) }
            // Sort by most recent
            recentActivity.sort { $0.timestamp > $1.timestamp }
        }

        guard let action = defaults?.string(forKey: "fp_progress_action"),
              let filename = defaults?.string(forKey: "fp_progress_filename") else {
            if fpProgress != nil {
                fpProgress = nil
                fpSpeed = 0
                fpLastBytes = 0
                fpLastTime = nil
            }
            return
        }
        let timestamp = defaults?.double(forKey: "fp_progress_timestamp") ?? 0
        if Date().timeIntervalSince1970 - timestamp > 30 {
            fpProgress = nil
            fpSpeed = 0
            fpLastBytes = 0
            fpLastTime = nil
            return
        }
        let bytes = Int64(defaults?.integer(forKey: "fp_progress_bytes") ?? 0)
        let total = Int64(defaults?.integer(forKey: "fp_progress_total") ?? 0)

        // Calculate speed — only during actual network transfer
        let now = Date()
        let isTransferring = action == "Uploading" || action == "Downloading"
        if isTransferring, let lastTime = fpLastTime, bytes > fpLastBytes {
            let elapsed = now.timeIntervalSince(lastTime)
            if elapsed > 0 {
                fpSpeed = Double(bytes - fpLastBytes) / elapsed
                speedHistory.append(fpSpeed)
                if speedHistory.count > 60 {
                    speedHistory.removeFirst(speedHistory.count - 60)
                }
            }
        } else if !isTransferring {
            fpSpeed = 0
        }
        fpLastBytes = bytes
        fpLastTime = now

        // Track completed uploads/downloads in recent activity
        if action == "Uploaded" || action == "Downloaded" {
            let alreadyTracked = recentActivity.contains { $0.filename == filename && abs($0.timestamp.timeIntervalSinceNow) < 5 }
            if !alreadyTracked {
                let item = ActivityItem(filename: filename, action: action.lowercased(), timestamp: Date())
                recentActivity.insert(item, at: 0)
                if recentActivity.count > 20 {
                    recentActivity = Array(recentActivity.prefix(20))
                }
            }
        }

        // Format progress string
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        if total > 0 {
            fpProgress = "\(action) \(filename) — \(formatter.string(fromByteCount: bytes)) / \(formatter.string(fromByteCount: total))"
        } else {
            fpProgress = "\(action) \(filename)"
        }
    }

    // MARK: - Device ID

    func getDeviceID() -> String {
        let key = "device_id"
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let newID = UUID().uuidString
        UserDefaults.standard.set(newID, forKey: key)
        return newID
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

    func togglePause() {
        isPaused.toggle()
        if !isPaused {
            Task { await runSync() }
        }
    }

    // MARK: - LAN/External URL Detection

    /// Detect the best URL to use: try LAN first (fast, 2s timeout), fall back to external.
    func detectBestURL() async -> String {
        if !lanURL.isEmpty {
            // Try a quick health check on LAN
            guard let url = URL(string: "\(lanURL)/api/health") else {
                return externalURL.isEmpty ? lanURL : externalURL
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = 2
            if let (_, response) = try? await URLSession.shared.data(for: request),
               let http = response as? HTTPURLResponse, http.statusCode == 200 {
                return lanURL
            }
        }
        return externalURL.isEmpty ? lanURL : externalURL
    }

    /// Update the API client's base URL to the best available URL.
    private func updateAPIClientURL() async {
        let bestURL = await detectBestURL()
        if !bestURL.isEmpty && bestURL != serverURL {
            logger.info("Switching to \(bestURL) (was \(self.serverURL))")
            serverURL = bestURL
            // Re-create API client with new URL while preserving auth
            if let oldClient = apiClient {
                let newClient = APIClient(baseURL: bestURL)
                if let token = KeychainHelper.load(key: "access_token") {
                    await newClient.setToken(token)
                }
                self.apiClient = newClient
            }
        }
    }

    func runSync() async {
        guard let client = apiClient, isConnected else {
            logger.info(" Not connected, skipping")
            return
        }
        guard !isPaused else {
            logger.info(" Sync paused, skipping")
            return
        }
        guard !isSyncing else {
            logger.info(" Already syncing, skipping")
            syncPending = true
            return
        }

        // Check if LAN is available and switch URL if needed
        if !lanURL.isEmpty || !externalURL.isEmpty {
            await updateAPIClientURL()
        }

        isSyncing = true
        syncPending = false
        syncProgress = nil
        speedHistory = []  // Clear speed history for fresh sync cycle
        startSpeedTracking()
        defer {
            isSyncing = false
            syncProgress = nil
            stopSpeedTracking()
            // Re-trigger if changes came in during sync
            if syncPending {
                syncPending = false
                Task { await runSync() }
            }
        }

        // Proactively refresh token before it expires
        do {
            // Test if token is still valid (use authenticated endpoint, not public health)
            let _ = try await client.listFiles(parentID: nil)
        } catch {
            logger.info(" Token check failed, re-authenticating...")
            if await client.reAuthenticate() {
                logger.info(" Re-authenticated successfully")
            } else {
                // Try with stored credentials directly
                if let password = KeychainHelper.load(key: "server_password") {
                    do {
                        try await client.login(username: username, password: password)
                        logger.info(" Re-logged in with stored credentials")
                    } catch {
                        logger.error(" Re-login failed: \(error)")
                        // Don't disconnect — try again next cycle
                        return
                    }
                } else {
                    // No stored password — can't re-auth
                    lastError = "Session expired — please reconnect"
                    isConnected = false
                    return
                }
            }
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
                guard let db = syncDatabase else {
                    logger.error("Sync database not initialized")
                    initSyncDatabase()
                    continue
                }
                let uploadLimit = Int64(UserDefaults.standard.integer(forKey: "uploadLimitBytesPerSecond"))
                let downloadLimit = Int64(UserDefaults.standard.integer(forKey: "downloadLimitBytesPerSecond"))
                let engine = SyncEngine(apiClient: client, db: db, uploadLimitBytesPerSecond: uploadLimit, downloadLimitBytesPerSecond: downloadLimit)

                // Get changed paths from FSEvents watcher (nil = full scan needed)
                var changedPaths = fileWatchers[task.id]?.consumeChangedPaths()

                // Load last successful sync date for this task (used to skip hashing unchanged files)
                let lastSyncKey = "lastSync_\(task.id.uuidString)"
                let lastSyncDate = UserDefaults.standard.object(forKey: lastSyncKey) as? Date

                // Empty FSEvents = no local changes. But we still need to check for
                // remote changes periodically (files deleted/added by other clients).
                // Do a full scan every 5th cycle even without local changes.
                let syncCountKey = "syncCount_\(task.id.uuidString)"
                let syncCount = UserDefaults.standard.integer(forKey: syncCountKey)
                UserDefaults.standard.set(syncCount + 1, forKey: syncCountKey)

                if let paths = changedPaths, paths.isEmpty, lastSyncDate != nil {
                    if syncCount % 5 != 0 {
                        logger.info("  No changes for \(task.remoteFolderName), skipping")
                        continue
                    }
                    // Every 5th cycle: force full scan to detect remote changes
                    logger.info("  Periodic full scan for \(task.remoteFolderName)")
                    changedPaths = nil
                }

                let result = try await engine.syncTask(task, changedPaths: changedPaths, lastSyncDate: lastSyncDate) { [weak self] progress in
                    await MainActor.run { [weak self] in
                        self?.syncProgress = progress
                        self?.syncQueue = progress.pendingFiles
                    }
                }

                logger.info(" Result: \(result.uploaded) up, \(result.downloaded) down, \(result.deleted) del, \(result.conflicts) conflicts, \(result.errors) errors")

                // Store last successful sync date (for optimized reconnect hashing)
                if result.errors == 0 {
                    UserDefaults.standard.set(Date(), forKey: lastSyncKey)
                }

                // Upload known state to server (for restore-to-new-Mac scenario)
                let deviceID = getDeviceID()
                let states = await engine.exportSyncStates(taskID: task.id.uuidString)
                try? await client.saveSyncStates(deviceID: deviceID, taskName: task.remoteFolderName, states: states)

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

        // Keep FileProvider credentials fresh (token expires after 24h)
        refreshFileProviderCredentials()

        // Update FinderSync badge state
        updateFinderSyncState()

        // After two-way sync, check on-demand uploads
        await syncOnDemandFiles(client)
    }

    // MARK: - On-Demand Bulk Upload

    /// Scans the on-demand CloudStorage folder and uploads any files not yet on the server.
    /// This runs after the two-way sync and catches files that the FileProvider failed to upload.
    private func syncOnDemandFiles(_ client: APIClient) async {
        // Find on-demand tasks
        let onDemandTasks = syncTasks.filter { $0.isEnabled && $0.mode == .onDemand }
        guard !onDemandTasks.isEmpty else { return }

        for task in onDemandTasks {
            // Find CloudStorage path — try multiple approaches since sandboxed apps have different home dirs
            let possiblePaths = [
                FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/CloudStorage/SyncVault-SyncVault-\(username)").path,
                NSHomeDirectory() + "/Library/CloudStorage/SyncVault-SyncVault-\(username)",
                "/Users/\(NSUserName())/Library/CloudStorage/SyncVault-SyncVault-\(username)",
            ]
            var cloudPath: String?
            for p in possiblePaths {
                logger.info("On-demand: trying path \(p)")
                if FileManager.default.fileExists(atPath: p) {
                    cloudPath = p
                    break
                }
            }
            guard let cloudPath = cloudPath else {
                logger.info("On-demand: CloudStorage path not found")
                continue
            }
            logger.info("On-demand: found at \(cloudPath)")

            do {
                // Get server file tree
                let remoteTree = try await client.getFileTree(folderID: task.remoteFolderID)
                let remoteNames = Set(remoteTree.filter { !$0.isDir }.map { $0.name })
                let remoteDirs = Set(remoteTree.filter { $0.isDir }.map { $0.relativePath })

                // Build folder ID cache from remote tree
                var folderCache: [String: String] = [:]
                for f in remoteTree where f.isDir {
                    folderCache[f.relativePath] = f.id
                }

                // Scan local files
                let fm = FileManager.default
                guard let enumerator = fm.enumerator(atPath: cloudPath) else { continue }

                var toUpload: [(fullPath: String, relativePath: String, parentRelPath: String)] = []

                var localFileCount = 0
                var localDirCount = 0
                while let relPath = enumerator.nextObject() as? String {
                    let fullPath = (cloudPath as NSString).appendingPathComponent(relPath)
                    let name = URL(fileURLWithPath: relPath).lastPathComponent
                    if name.hasPrefix(".") || name == ".DS_Store" { continue }

                    guard let attrs = try? fm.attributesOfItem(atPath: fullPath) else { continue }
                    let isDir = attrs[.type] as? FileAttributeType == .typeDirectory

                    if isDir {
                        // Create missing directories on server
                        if folderCache[relPath] == nil {
                            let parentRel = (relPath as NSString).deletingLastPathComponent
                            let parentID = parentRel.isEmpty ? task.remoteFolderID : (folderCache[parentRel] ?? task.remoteFolderID)
                            do {
                                let folder = try await client.createFolder(name: name, parentID: parentID)
                                folderCache[relPath] = folder.id
                                logger.info("On-demand: created dir \(relPath)")
                            } catch {
                                // Folder might already exist
                            }
                        }
                    } else {
                        // Check if file needs uploading by checking relative path in remote tree
                        let remoteMatch = remoteTree.first { $0.relativePath == relPath && !$0.isDir }
                        if remoteMatch == nil {
                            let parentRel = (relPath as NSString).deletingLastPathComponent
                            toUpload.append((fullPath, relPath, parentRel))
                        }
                    }
                }

                let remoteFileCount = remoteTree.filter { !$0.isDir }.count
                let localScanned = toUpload.count + remoteFileCount

                logger.info("On-demand: scanned local, found \(toUpload.count) to upload + \(remoteFileCount) already on server")

                if toUpload.isEmpty {
                    logger.info("On-demand: all synced (\(remoteFileCount) on server)")
                    continue
                }

                logger.info("On-demand: \(toUpload.count) files to upload")

                // Upload missing files via block upload (same as sync engine)
                guard let db = syncDatabase else { continue }
                let engine = SyncEngine(apiClient: client, db: db)

                for (i, item) in toUpload.prefix(50).enumerated() {
                    let fileURL = URL(fileURLWithPath: item.fullPath)
                    let name = fileURL.lastPathComponent
                    let parentID = item.parentRelPath.isEmpty ? task.remoteFolderID : (folderCache[item.parentRelPath] ?? task.remoteFolderID)

                    do {
                        let attrs = try fm.attributesOfItem(atPath: item.fullPath)
                        let fileSize = (attrs[.size] as? Int64) ?? 0

                        fpProgress = "Uploading \(name) (\(i+1)/\(min(toUpload.count, 50)))"

                        let _ = try await engine.uploadViaBlocksPublic(
                            fileURL: fileURL, filename: name, parentID: parentID, fileSize: fileSize
                        )
                        logger.info("On-demand uploaded: \(item.relativePath) (\(fileSize) bytes)")
                    } catch {
                        logger.error("On-demand upload failed: \(item.relativePath): \(error)")
                    }
                }

                fpProgress = nil
            } catch {
                logger.error("On-demand sync error: \(error)")
            }
        }
    }

    /// Update FinderSync extension with current sync task mapping and notify of state changes.
    private func updateFinderSyncState() {
        let defaults = UserDefaults(suiteName: "DE59N86W33.com.syncvault.shared")

        // Write task mapping: localPath → taskID (only sync/backup, not on-demand)
        var mapping: [String: String] = [:]
        for task in syncTasks where task.isEnabled && task.mode != .onDemand {
            mapping[task.localPath] = task.id.uuidString
        }
        if let d = defaults {
            // Store as JSON string (UserDefaults dictionaries can be unreliable across processes)
            if let jsonData = try? JSONSerialization.data(withJSONObject: mapping),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                d.set(jsonString, forKey: "syncTaskMapping")
            }
            d.removeObject(forKey: "syncingFiles")
            d.synchronize()
            logger.info("FinderSync: updated task mapping with \(mapping.count) tasks")
        } else {
            logger.error("FinderSync: could not access shared UserDefaults!")
        }

        // Notify FinderSync to refresh badges
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("com.syncvault.syncCompleted"),
            object: nil
        )
    }

    /// Refresh FileProvider shared credentials so the extension can re-auth when tokens expire.
    private func refreshFileProviderCredentials() {
        guard isConnected else { return }
        let hasOnDemand = syncTasks.contains { $0.isEnabled && $0.mode == .onDemand }
        guard hasOnDemand else { return }

        if let token = KeychainHelper.load(key: "access_token") {
            KeychainHelper.saveShared(key: "access_token", value: token)
        }
        KeychainHelper.saveShared(key: "fp_username", value: username)
        if let password = KeychainHelper.load(key: "server_password") {
            KeychainHelper.saveShared(key: "fp_password", value: password)
        }
    }

    // MARK: - On-Demand Sync (File Provider)

    func setupOnDemandSync(folderID: String) async throws {
        guard isConnected else { throw APIError.unauthorized }
        guard !folderID.isEmpty else { throw APIError.serverError(400) }

        let sharedDefaults = UserDefaults(suiteName: "DE59N86W33.com.syncvault.shared")!
        sharedDefaults.set(folderID, forKey: "onDemandFolderID")
        sharedDefaults.set(serverURL, forKey: "serverURL")

        // Share auth credentials with FileProvider extension for re-auth
        if let token = KeychainHelper.load(key: "access_token") {
            KeychainHelper.saveShared(key: "access_token", value: token)
        }
        KeychainHelper.saveShared(key: "fp_username", value: username)
        if let password = KeychainHelper.load(key: "server_password") {
            KeychainHelper.saveShared(key: "fp_password", value: password)
        }

        let domainIdentifier = NSFileProviderDomainIdentifier("com.syncvault.\(username)")
        let domain = NSFileProviderDomain(
            identifier: domainIdentifier,
            displayName: "SyncVault - \(username)"
        )

        // Remove existing domain first to force clean re-enumeration
        try? await NSFileProviderManager.remove(domain)
        try await NSFileProviderManager.add(domain)

        // Signal the manager to re-enumerate from scratch
        if let manager = NSFileProviderManager(for: domain) {
            manager.signalEnumerator(for: .rootContainer) { _ in }
        }
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
