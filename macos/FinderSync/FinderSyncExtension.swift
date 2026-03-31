import Cocoa
import FinderSync
import os

class FinderSyncExtension: FIFinderSync {
    private let logger = Logger(subsystem: "com.syncvault.findersync", category: "FinderSync")

    override init() {
        super.init()
        logger.info("FinderSync Extension initialized")

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
            NSImage(systemSymbolName: "icloud.circle.fill", accessibilityDescription: "Cloud")!
                .withSymbolConfiguration(.init(paletteColors: [.systemGray]))!,
            label: "Cloud Only",
            forBadgeIdentifier: "cloud"
        )

        // Load monitored paths from shared UserDefaults
        updateMonitoredPaths()

        // Watch for changes to monitored paths
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(pathsChanged),
            name: NSNotification.Name("com.syncvault.monitoredPathsChanged"),
            object: nil
        )
    }

    @objc private func pathsChanged() {
        updateMonitoredPaths()
    }

    private func updateMonitoredPaths() {
        let defaults = UserDefaults(suiteName: "DE59N86W33.com.syncvault.shared")
        if let paths = defaults?.stringArray(forKey: "monitoredPaths"), !paths.isEmpty {
            let urls = Set(paths.map { URL(fileURLWithPath: $0) })
            FIFinderSyncController.default().directoryURLs = urls
            logger.info("Monitoring \(urls.count) paths")
        } else {
            FIFinderSyncController.default().directoryURLs = []
            logger.info("No paths to monitor")
        }
    }

    // MARK: - Badge Icons

    override func requestBadgeIdentifier(for url: URL) {
        // All files in monitored folders are "synced" by default
        FIFinderSyncController.default().setBadgeIdentifier("synced", for: url)
    }

    // MARK: - Context Menu

    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        let menu = NSMenu(title: "SyncVault")

        let shareItem = NSMenuItem(title: "Copy Share Link", action: #selector(shareLink(_:)), keyEquivalent: "")
        shareItem.image = NSImage(systemSymbolName: "link", accessibilityDescription: nil)
        menu.addItem(shareItem)

        let versionsItem = NSMenuItem(title: "View Versions", action: #selector(viewVersions(_:)), keyEquivalent: "")
        versionsItem.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)
        menu.addItem(versionsItem)

        let openItem = NSMenuItem(title: "Open on Server", action: #selector(openOnServer(_:)), keyEquivalent: "")
        openItem.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        menu.addItem(openItem)

        return menu
    }

    @IBAction func shareLink(_ sender: AnyObject?) {
        guard let items = FIFinderSyncController.default().selectedItemURLs(), let url = items.first else { return }
        logger.info("Share link requested for: \(url.lastPathComponent)")

        // Get server URL from shared defaults
        let defaults = UserDefaults(suiteName: "DE59N86W33.com.syncvault.shared")
        let serverURL = defaults?.string(forKey: "serverURL") ?? ""

        // Copy a placeholder share link to clipboard
        let shareURL = "\(serverURL)/files"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(shareURL, forType: .string)

        // Show notification
        let notification = NSUserNotification()
        notification.title = "SyncVault"
        notification.informativeText = "Share link copied to clipboard"
        NSUserNotificationCenter.default.deliver(notification)
    }

    @IBAction func viewVersions(_ sender: AnyObject?) {
        guard let items = FIFinderSyncController.default().selectedItemURLs(), let url = items.first else { return }
        logger.info("View versions requested for: \(url.lastPathComponent)")

        let defaults = UserDefaults(suiteName: "DE59N86W33.com.syncvault.shared")
        let serverURL = defaults?.string(forKey: "serverURL") ?? ""
        if let webURL = URL(string: "\(serverURL)/files") {
            NSWorkspace.shared.open(webURL)
        }
    }

    @IBAction func openOnServer(_ sender: AnyObject?) {
        guard let items = FIFinderSyncController.default().selectedItemURLs(), let url = items.first else { return }
        logger.info("Open on server requested for: \(url.lastPathComponent)")

        let defaults = UserDefaults(suiteName: "DE59N86W33.com.syncvault.shared")
        let serverURL = defaults?.string(forKey: "serverURL") ?? ""
        if let webURL = URL(string: "\(serverURL)/files") {
            NSWorkspace.shared.open(webURL)
        }
    }
}
