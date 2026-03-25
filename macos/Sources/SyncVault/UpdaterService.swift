import Foundation
import AppKit
import os

private let logger = Logger(subsystem: "com.syncvault.app", category: "Updater")

@MainActor
class UpdaterService: ObservableObject {
    @Published var availableVersion: String?
    @Published var availableChangelog: String?
    @Published var isDownloading = false
    @Published var automaticallyChecksForUpdates: Bool {
        didSet { UserDefaults.standard.set(automaticallyChecksForUpdates, forKey: "autoCheckUpdates") }
    }

    private let versionURL = "https://raw.githubusercontent.com/NielHeesakkers/SyncVault/main/version.json"

    init() {
        self.automaticallyChecksForUpdates = UserDefaults.standard.bool(forKey: "autoCheckUpdates")
        // Check in background on launch
        if automaticallyChecksForUpdates {
            Task { await checkForUpdatesInBackground() }
        }
    }

    // MARK: - Background check (no alert if up to date)

    func checkForUpdatesInBackground() async {
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        guard let (latestVersion, changelog) = await fetchVersionInfo() else { return }

        if compareVersions(latestVersion, isNewerThan: currentVersion) {
            availableVersion = latestVersion
            availableChangelog = changelog
            logger.info("Update available: \(latestVersion)")
        }
    }

    // MARK: - Manual check (shows alert)

    func checkForUpdates() {
        Task {
            let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
            guard let (latestVersion, changelog) = await fetchVersionInfo() else {
                showAlert(title: "Update Check Failed", message: "Could not reach update server.")
                return
            }

            if compareVersions(latestVersion, isNewerThan: currentVersion) {
                availableVersion = latestVersion
                availableChangelog = changelog

                let alert = NSAlert()
                alert.messageText = "Update Available"
                alert.informativeText = "SyncVault v\(latestVersion) is available (you have v\(currentVersion)).\(changelog ?? "")"
                alert.alertStyle = .informational
                alert.addButton(withTitle: "Download Update")
                alert.addButton(withTitle: "Later")
                if alert.runModal() == .alertFirstButtonReturn {
                    downloadAndInstallUpdate(version: latestVersion)
                }
            } else {
                availableVersion = nil
                availableChangelog = nil
                showAlert(title: "You're Up to Date", message: "SyncVault v\(currentVersion) is the latest version.")
            }
        }
    }

    // MARK: - Download & Install

    func downloadAndInstallUpdate(version: String) {
        let dmgURL = "https://github.com/NielHeesakkers/SyncVault/releases/download/v\(version)/SyncVault-\(version).dmg"
        guard let url = URL(string: dmgURL) else { return }

        isDownloading = true
        logger.info("Downloading update v\(version) from \(dmgURL)")

        let tempDir = FileManager.default.temporaryDirectory
        let dmgPath = tempDir.appendingPathComponent("SyncVault-update.dmg")
        try? FileManager.default.removeItem(at: dmgPath)

        let task = URLSession.shared.downloadTask(with: url) { [weak self] tempURL, response, error in
            DispatchQueue.main.async {
                self?.isDownloading = false

                guard let tempURL = tempURL, error == nil else {
                    self?.showAlert(title: "Update Failed", message: "Download failed: \(error?.localizedDescription ?? "Unknown error")")
                    return
                }

                do {
                    try FileManager.default.moveItem(at: tempURL, to: dmgPath)
                    self?.installUpdate(dmgPath: dmgPath)
                } catch {
                    self?.showAlert(title: "Update Failed", message: "Could not save download.")
                }
            }
        }
        task.resume()
    }

    private func installUpdate(dmgPath: URL) {
        let scriptPath = "/tmp/syncvault_update.sh"
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        #!/bin/bash
        set -e
        while kill -0 \(pid) 2>/dev/null; do sleep 0.5; done
        MOUNT_POINT=$(hdiutil attach "\(dmgPath.path)" -nobrowse -noverify | grep "/Volumes/" | awk -F'\\t' '{print $NF}')
        if [ -d "$MOUNT_POINT/SyncVault.app" ]; then
            rm -rf "/Applications/SyncVault.app"
            cp -R "$MOUNT_POINT/SyncVault.app" "/Applications/"
            hdiutil detach "$MOUNT_POINT" -quiet
            rm -f "\(dmgPath.path)"
            open "/Applications/SyncVault.app"
        else
            hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || true
        fi
        rm -f "\(scriptPath)"
        """

        do {
            try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            proc.arguments = ["-c", "chmod +x \(scriptPath) && nohup \(scriptPath) &>/dev/null &"]
            try proc.run()
            proc.waitUntilExit()

            logger.info("Update script launched, quitting app...")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                NSApplication.shared.terminate(nil)
            }
        } catch {
            showAlert(title: "Update Failed", message: "Could not install update: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    private func fetchVersionInfo() async -> (version: String, changelog: String?)? {
        let cacheBust = "\(versionURL)?t=\(Int(Date().timeIntervalSince1970))"
        guard let url = URL(string: cacheBust) else { return nil }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let latestVersion = json["version"] as? String else { return nil }

            var changelog: String? = nil
            if let history = json["history"] as? [[String: Any]],
               let latest = history.first,
               let changes = latest["changes"] as? [String] {
                changelog = "\n\nWhat's new:\n• " + changes.joined(separator: "\n• ")
            }

            return (latestVersion, changelog)
        } catch {
            logger.error("Failed to fetch version info: \(error)")
            return nil
        }
    }

    private func compareVersions(_ v1: String, isNewerThan v2: String) -> Bool {
        let parts1 = v1.split(separator: ".").compactMap { Int($0) }
        let parts2 = v2.split(separator: ".").compactMap { Int($0) }
        let maxLen = max(parts1.count, parts2.count)
        for i in 0..<maxLen {
            let a = i < parts1.count ? parts1[i] : 0
            let b = i < parts2.count ? parts2[i] : 0
            if a > b { return true }
            if a < b { return false }
        }
        return false
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.runModal()
    }
}
