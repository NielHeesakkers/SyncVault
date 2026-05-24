import Foundation
import AppKit
import os

private let logger = Logger(subsystem: "com.syncvault.app", category: "Updater")

/// Manages the in-app update flow.
///
/// The flow is split into TWO user-visible steps so the user controls when the
/// app actually quits:
///
///   1. `downloadUpdate(version:)` → DMG streams in the background, `downloadProgress`
///      ticks 0.0–1.0, `downloadedDMG` is nil until the file has been moved to its
///      staging path.
///   2. `quitAndInstall()` → runs the install script (kills both app extensions
///      first so the bundle isn't locked), quits the app, lets the script swap
///      `/Applications/SyncVault.app`, then relaunches.
///
/// The install script logs to `/tmp/syncvault_update.log` so we can debug failures
/// post-mortem instead of swallowing errors into `/dev/null`.
@MainActor
class UpdaterService: ObservableObject {
    @Published var availableVersion: String?
    @Published var availableChangelog: String?

    // Download state — drives the progress bar / install button in the UI.
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0          // 0.0 – 1.0
    @Published var downloadedDMG: URL?                   // non-nil → ready to install
    @Published var downloadError: String?

    @Published var automaticallyChecksForUpdates: Bool {
        didSet { UserDefaults.standard.set(automaticallyChecksForUpdates, forKey: "autoCheckUpdates") }
    }

    private let versionURL = "https://raw.githubusercontent.com/NielHeesakkers/SyncVault/main/version.json"

    // Retain the session + delegate for the lifetime of the download.
    private var downloadSession: URLSession?
    private var downloadDelegate: DownloadDelegate?

    init() {
        self.automaticallyChecksForUpdates = UserDefaults.standard.bool(forKey: "autoCheckUpdates")
        if automaticallyChecksForUpdates {
            Task { await checkForUpdatesInBackground() }
        }
    }

    // MARK: - Check

    func checkForUpdatesInBackground() async {
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        guard let (latestVersion, changelog) = await fetchVersionInfo() else { return }

        if compareVersions(latestVersion, isNewerThan: currentVersion) {
            availableVersion = latestVersion
            availableChangelog = changelog
            logger.info("Update available: \(latestVersion)")
        }
    }

    /// Manual check — always shows an alert (either "up to date" or the new-version prompt).
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
                // UI picks up the new state automatically (the progress bar + install button
                // live in the Settings/menu views). No modal — keeps things calm.
            } else {
                availableVersion = nil
                availableChangelog = nil
                showAlert(title: "You're Up to Date", message: "SyncVault v\(currentVersion) is the latest version.")
            }
        }
    }

    // MARK: - Download

    /// Download the DMG for `version` into ~/Library/Application Support/SyncVault/Updates/.
    /// Updates `downloadProgress` live; on success sets `downloadedDMG` so the UI can
    /// flip to a "Quit & Install" button.
    func downloadUpdate(version: String) {
        guard !isDownloading else { return }

        let dmgURLString = "https://github.com/NielHeesakkers/SyncVault/releases/download/v\(version)/SyncVault-\(version).dmg"
        guard let url = URL(string: dmgURLString) else { return }

        isDownloading = true
        downloadProgress = 0
        downloadedDMG = nil
        downloadError = nil

        // Stage outside the sandbox so the install script (running as the user) can read it.
        let updateDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("SyncVault/Updates")
        try? FileManager.default.createDirectory(at: updateDir, withIntermediateDirectories: true)
        let dmgPath = updateDir.appendingPathComponent("SyncVault-update.dmg")
        try? FileManager.default.removeItem(at: dmgPath)

        logger.info("Downloading update v\(version) from \(dmgURLString)")

        let delegate = DownloadDelegate(
            destination: dmgPath,
            onProgress: { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.downloadProgress = progress
                }
            },
            onComplete: { [weak self] result in
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    self.isDownloading = false
                    switch result {
                    case .success(let savedURL):
                        self.downloadedDMG = savedURL
                        self.downloadProgress = 1.0
                        logger.info("Update downloaded to \(savedURL.path)")
                    case .failure(let error):
                        self.downloadError = error.localizedDescription
                        self.downloadProgress = 0
                        logger.error("Download failed: \(error.localizedDescription)")
                    }
                    self.downloadDelegate = nil
                    self.downloadSession?.invalidateAndCancel()
                    self.downloadSession = nil
                }
            }
        )
        downloadDelegate = delegate
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        downloadSession = session
        session.downloadTask(with: url).resume()
    }

    /// Cancel an in-progress download.
    func cancelDownload() {
        downloadSession?.invalidateAndCancel()
        downloadSession = nil
        downloadDelegate = nil
        isDownloading = false
        downloadProgress = 0
    }

    // MARK: - Install

    /// Launches the install script and quits. The script swaps the bundle in
    /// /Applications and relaunches the new app. The user must have a downloaded
    /// DMG (call downloadUpdate first).
    func quitAndInstall() {
        guard let dmg = downloadedDMG else {
            logger.error("quitAndInstall called but no DMG downloaded")
            return
        }
        installUpdate(dmgPath: dmg)
    }

    private func installUpdate(dmgPath: URL) {
        // The script lives next to the DMG so it's also outside the sandbox.
        let scriptPath = dmgPath.deletingLastPathComponent().appendingPathComponent("syncvault_update.sh").path
        let logPath = dmgPath.deletingLastPathComponent().appendingPathComponent("syncvault_update.log").path
        let pid = ProcessInfo.processInfo.processIdentifier

        // Why every line matters:
        //  * exec >> logfile  → so failed installs leave a trace instead of silently dying
        //  * wait for main pid → don't replace the bundle while we're still running it
        //  * pkill the extensions → FileProvider + FinderSync are loaded by system services
        //    and keep the .app bundle locked even after the main app quits; without this
        //    rm -rf fails and the user is left with the old version
        //  * mv fallback → if rm still can't remove (e.g. someone re-opened it), at least
        //    we side-step the live bundle so ditto can write the new one in place
        //  * xattr -cr → clear quarantine bit Gatekeeper adds to downloaded apps
        let script = """
        #!/bin/bash
        # Log everything; never silently fail again
        exec >> "\(logPath)" 2>&1
        echo "=== SyncVault update started at $(date) ==="

        # Wait for the running main process to exit
        echo "Waiting for app pid \(pid) to exit…"
        while kill -0 \(pid) 2>/dev/null; do sleep 0.3; done
        echo "Main app exited"

        # Kill any leftover extension processes that keep the bundle locked
        # (FileProvider and FinderSync run as system-managed child processes)
        pkill -f "SyncVaultFileProvider" 2>/dev/null || true
        pkill -f "SyncVaultFinderSync"  2>/dev/null || true
        # Give launchd a moment to actually reap them
        sleep 1
        echo "Extensions killed"

        DMG="\(dmgPath.path)"
        APP_DEST="/Applications/SyncVault.app"

        # Mount the DMG (no browse window, skip cosmetic verify for speed)
        MOUNT_POINT=$(hdiutil attach "$DMG" -nobrowse -noverify | grep "/Volumes/" | awk -F'\\t' '{print $NF}')
        echo "Mounted: $MOUNT_POINT"

        if [ -z "$MOUNT_POINT" ] || [ ! -d "$MOUNT_POINT/SyncVault.app" ]; then
            echo "ERROR: SyncVault.app not found in DMG ($MOUNT_POINT)"
            hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || true
            exit 1
        fi

        # Remove old bundle. Retry a few times; if it still won't go, move it aside
        # so ditto can write the new one without conflict.
        for i in 1 2 3; do
            if rm -rf "$APP_DEST" 2>/dev/null; then
                echo "Removed old bundle (attempt $i)"
                break
            fi
            echo "rm attempt $i failed, sleeping…"
            sleep 1
        done
        if [ -d "$APP_DEST" ]; then
            backup="/Applications/SyncVault.app.old-$(date +%s)"
            mv "$APP_DEST" "$backup" 2>/dev/null || true
            echo "Moved stuck bundle to $backup"
        fi

        # Copy the new bundle (ditto preserves resource forks + extended attrs correctly)
        ditto "$MOUNT_POINT/SyncVault.app" "$APP_DEST"
        if [ $? -ne 0 ]; then
            echo "ERROR: ditto failed"
            hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || true
            exit 1
        fi

        # Strip quarantine so Gatekeeper doesn't show a scary dialog on first launch
        xattr -cr "$APP_DEST"
        echo "Installed new bundle"

        hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || true
        rm -f "$DMG"

        # Re-launch
        open "$APP_DEST"
        echo "Relaunched"

        # Self-delete (best-effort)
        rm -f "\(scriptPath)"
        echo "=== Update complete at $(date) ==="
        """

        do {
            try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            // chmod first, then nohup the script so it survives our termination
            proc.arguments = ["-c", "chmod +x '\(scriptPath)' && nohup '\(scriptPath)' </dev/null >/dev/null 2>&1 &"]
            try proc.run()
            proc.waitUntilExit()

            logger.info("Update script launched (log: \(logPath)), quitting in 1s…")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                NSApplication.shared.terminate(nil)
            }
        } catch {
            downloadError = "Could not start install: \(error.localizedDescription)"
            showAlert(title: "Update Failed", message: downloadError ?? "Unknown error")
            logger.error("Install script launch failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    private func fetchVersionInfo() async -> (version: String, changelog: String?)? {
        let cacheBust = "\(versionURL)?t=\(Int(Date().timeIntervalSince1970))"
        guard let url = URL(string: cacheBust) else { return nil }

        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
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
            logger.error("Failed to fetch version info: \(error.localizedDescription)")
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

// MARK: - Download delegate

/// URLSessionDownloadDelegate that streams progress callbacks and atomically
/// moves the finished file out of the temp dir before completion fires (the
/// delegate's temp file is deleted as soon as didFinishDownloadingTo returns).
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    private let destination: URL
    private let onProgress: (Double) -> Void
    private let onComplete: (Result<URL, Error>) -> Void

    init(destination: URL,
         onProgress: @escaping (Double) -> Void,
         onComplete: @escaping (Result<URL, Error>) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
        self.onComplete = onComplete
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        onProgress(progress)
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // Move synchronously before the system removes the temp file.
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            onComplete(.success(destination))
        } catch {
            onComplete(.failure(error))
        }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if let error = error {
            // didFinishDownloadingTo also calls onComplete on success, so only
            // forward errors here.
            onComplete(.failure(error))
        }
    }
}
