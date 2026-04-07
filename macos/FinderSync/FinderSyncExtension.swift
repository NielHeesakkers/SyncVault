import Cocoa
import FinderSync
import SQLite3
import os

@objc(FinderSyncExtension)
class FinderSyncExtension: FIFinderSync {
    private let logger = Logger(subsystem: "com.syncvault.findersync", category: "FinderSync")
    private var taskMapping: [String: String] = [:]  // localPath → taskID
    private var syncingFiles: Set<String> = []
    private var syncedPaths: Set<String> = []  // cache of synced relative paths

    override init() {
        super.init()
        NSLog("SyncVault FinderSync: INIT")

        // Register badge images
        FIFinderSyncController.default().setBadgeImage(
            NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Synced")!
                .withSymbolConfiguration(.init(paletteColors: [.systemGreen]))!,
            label: "Synced",
            forBadgeIdentifier: "synced"
        )
        FIFinderSyncController.default().setBadgeImage(
            NSImage(systemSymbolName: "arrow.triangle.2.circlepath.circle.fill", accessibilityDescription: "Syncing")!
                .withSymbolConfiguration(.init(paletteColors: [.systemBlue]))!,
            label: "Syncing",
            forBadgeIdentifier: "syncing"
        )
        FIFinderSyncController.default().setBadgeImage(
            NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Error")!
                .withSymbolConfiguration(.init(paletteColors: [.systemOrange]))!,
            label: "Error",
            forBadgeIdentifier: "error"
        )

        // Always set at least one path so Finder loads us
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: NSHomeDirectory() + "/Desktop")]

        // Load state
        reloadState()
        loadSyncedPaths()

        // Watch for changes
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(stateChanged),
            name: NSNotification.Name("com.syncvault.syncCompleted"), object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(stateChanged),
            name: NSNotification.Name("com.syncvault.monitoredPathsChanged"), object: nil
        )
    }

    @objc private func stateChanged() {
        NSLog("SyncVault FinderSync: stateChanged notification")
        reloadState()
        loadSyncedPaths()
    }

    private func reloadState() {
        let defaults = UserDefaults(suiteName: "DE59N86W33.com.syncvault.shared")

        // Load task mapping (JSON string)
        if let json = defaults?.string(forKey: "syncTaskMapping"),
           let data = json.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            taskMapping = dict
        } else {
            taskMapping = [:]
        }

        // Load syncing files
        syncingFiles = Set(defaults?.stringArray(forKey: "syncingFiles") ?? [])

        // Set monitored directories
        if !taskMapping.isEmpty {
            let urls = Set(taskMapping.keys.map { URL(fileURLWithPath: $0) })
            FIFinderSyncController.default().directoryURLs = urls
            NSLog("SyncVault FinderSync: monitoring %d paths", urls.count)
        } else {
            // Fallback: use monitoredPaths but exclude CloudStorage (on-demand)
            if let paths = defaults?.stringArray(forKey: "monitoredPaths") {
                let syncPaths = paths.filter { !$0.contains("CloudStorage") && !$0.contains("~") }
                if !syncPaths.isEmpty {
                    FIFinderSyncController.default().directoryURLs = Set(syncPaths.map { URL(fileURLWithPath: $0) })
                    NSLog("SyncVault FinderSync: fallback monitoring %d paths", syncPaths.count)
                }
            }
        }
    }

    /// Load synced file paths from the sync database using raw sqlite3
    private func loadSyncedPaths() {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "DE59N86W33.com.syncvault.shared"
        ) else { return }

        let dbPath = containerURL.appendingPathComponent("sync.db").path
        guard FileManager.default.fileExists(atPath: dbPath) else { return }

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return }
        defer { sqlite3_close(db) }

        var newPaths = Set<String>()
        var stmt: OpaquePointer?
        let sql = "SELECT task_id, relative_path FROM sync_states_v2"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let taskIDCStr = sqlite3_column_text(stmt, 0),
                  let relPathCStr = sqlite3_column_text(stmt, 1) else { continue }
            let taskID = String(cString: taskIDCStr)
            let relPath = String(cString: relPathCStr)

            // Find the local path for this task
            for (localPath, tID) in taskMapping where tID == taskID {
                let fullPath = (localPath as NSString).appendingPathComponent(relPath)
                newPaths.insert(fullPath)
            }
        }

        syncedPaths = newPaths
        NSLog("SyncVault FinderSync: loaded %d synced paths", syncedPaths.count)
    }

    // MARK: - Badge Icons

    override func requestBadgeIdentifier(for url: URL) {
        let path = url.path

        // 1. Currently syncing?
        if syncingFiles.contains(path) {
            FIFinderSyncController.default().setBadgeIdentifier("syncing", for: url)
            return
        }

        // 2. Check if synced (in database)
        if syncedPaths.contains(path) {
            FIFinderSyncController.default().setBadgeIdentifier("synced", for: url)
            return
        }

        // 3. Check if it's the root folder of a task
        if taskMapping.keys.contains(path) {
            FIFinderSyncController.default().setBadgeIdentifier("synced", for: url)
            return
        }

        // No badge = not yet synced
    }

    // MARK: - Context Menu

    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        let menu = NSMenu(title: "SyncVault")

        let shareItem = NSMenuItem(title: "Copy Share Link", action: #selector(shareLink(_:)), keyEquivalent: "")
        shareItem.image = NSImage(systemSymbolName: "link", accessibilityDescription: nil)
        menu.addItem(shareItem)

        let openItem = NSMenuItem(title: "Open on Server", action: #selector(openOnServer(_:)), keyEquivalent: "")
        openItem.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        menu.addItem(openItem)

        return menu
    }

    @IBAction func shareLink(_ sender: AnyObject?) {
        let defaults = UserDefaults(suiteName: "DE59N86W33.com.syncvault.shared")
        let serverURL = defaults?.string(forKey: "serverURL") ?? ""
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("\(serverURL)/files", forType: .string)
    }

    @IBAction func openOnServer(_ sender: AnyObject?) {
        let defaults = UserDefaults(suiteName: "DE59N86W33.com.syncvault.shared")
        let serverURL = defaults?.string(forKey: "serverURL") ?? ""
        if let webURL = URL(string: "\(serverURL)/files") {
            NSWorkspace.shared.open(webURL)
        }
    }
}
