import SwiftUI
import AppKit

struct MenuBarView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var updaterService: UpdaterService

    var activeTasks: Int {
        appState.syncTasks.filter { $0.isEnabled }.count
    }

    var backupTasks: [SyncTask] {
        appState.syncTasks.filter { $0.mode != .onDemand }
    }

    var onDemandTasks: [SyncTask] {
        appState.syncTasks.filter { $0.mode == .onDemand }
    }

    var hasBackupTasks: Bool { !backupTasks.isEmpty }
    var hasOnDemandTasks: Bool { !onDemandTasks.isEmpty }

    var allTasks: [SyncTask] {
        appState.syncTasks.filter { $0.isEnabled }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusHeader
                .overlay(
                    Rectangle().fill(SVColor.hairline).frame(height: 1),
                    alignment: .bottom
                )

            if appState.isConnected {
                nowSyncingSection
                recentlyChangedSection
                if !appState.syncTasks.isEmpty {
                    syncTasksSection
                }
            }

            actionsSection

            footerView
        }
        .frame(width: 340)
        .background(SVColor.windowBg)
    }

    // MARK: - Status Header

    private var statusHeader: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(appState.isSyncing ? SVColor.cloudTint : SVColor.liveTint)
                    .frame(width: 32, height: 32)
                Text(appState.isSyncing ? "↻" : "✓")
                    .font(.system(size: 14))
                    .foregroundStyle(appState.isSyncing ? SVColor.cloudFg : SVColor.accentGreen)
                    .rotationEffect(.degrees(appState.isSyncing ? 360 : 0))
                    .animation(appState.isSyncing
                        ? .linear(duration: 2).repeatForever(autoreverses: false)
                        : .default, value: appState.isSyncing)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(headerTitle).font(SVFont.bodyBold(14))
                Text(headerSub).font(SVFont.mono(11)).foregroundStyle(SVColor.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, SVSpacing.xl)
        .padding(.vertical, SVSpacing.xl)
    }

    private var headerTitle: String {
        if appState.isSyncing, let name = appState.activeSyncTaskName { return "Syncing \(name)" }
        if appState.isSyncing { return "Syncing…" }
        if !appState.isConnected { return "Disconnected" }
        return "Up to date"
    }

    private var headerSub: String {
        let count = appState.syncTasks.count
        let host = URL(string: appState.serverURL)?.host ?? appState.serverURL
        let size = ByteCountFormatter.string(fromByteCount: appState.storageUsed, countStyle: .file)
        return "\(count) tasks · \(size) · \(host)"
    }

    // MARK: - Now Syncing (live in-flight uploads)

    @ViewBuilder
    private var nowSyncingSection: some View {
        if !appState.activeUploads.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                SVSectionLabel(text: "Now syncing")
                let items = appState.activeUploads.values.sorted { $0.startedAt < $1.startedAt }
                ForEach(Array(items.prefix(3))) { upload in
                    HStack(spacing: 10) {
                        SVChip(variant: .file)
                        SVProgressStrip(
                            filename: upload.filename,
                            progress: upload.totalBytes > 0
                                ? Double(upload.bytesTransferred) / Double(upload.totalBytes)
                                : 0,
                            fillColor: SVColor.accentGreen
                        )
                    }
                    .padding(8)
                    .background(SVColor.liveTint.opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: SVRadius.chip))
                }
                if appState.activeUploads.count > 3 {
                    Text("+ \(appState.activeUploads.count - 3) more")
                        .font(SVFont.mono(10.5))
                        .foregroundStyle(SVColor.textSecondary)
                }
            }
            .padding(.horizontal, SVSpacing.xl)
            .padding(.top, SVSpacing.l)
        }
    }

    // MARK: - Recently Changed

    @ViewBuilder
    private var recentlyChangedSection: some View {
        if !appState.recentActivity.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                SVSectionLabel(text: "Recently changed")
                ForEach(appState.recentActivity.prefix(3)) { item in
                    HStack(spacing: 10) {
                        SVChip(variant: .file)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.filename)
                                .font(SVFont.body(12.5))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text("\(item.taskName) · \(relativeTime(item.timestamp))")
                                .font(SVFont.body(10.5))
                                .foregroundStyle(SVColor.textSecondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                    .onTapGesture { openRecentFile(item) }
                }
            }
            .padding(.horizontal, SVSpacing.xl)
            .padding(.top, SVSpacing.l)
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }

    // MARK: - Unified Sync Tasks (backup + on-demand together)

    private var syncTasksSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SVSectionLabel(text: "Sync tasks", count: "\(syncedCount) / \(appState.syncTasks.count)")
                .padding(.top, SVSpacing.l)
            ForEach(sortedTasks) { task in
                syncTaskRow(task)
                if task.id == sortedTasks.first?.id,
                   sortedTasks.first?.mode == .onDemand,
                   sortedTasks.count > 1 {
                    Rectangle()
                        .fill(LinearGradient(
                            colors: [.clear, SVColor.hairline, .clear],
                            startPoint: .leading, endPoint: .trailing
                        ))
                        .frame(height: 1)
                        .padding(.vertical, 4)
                }
            }
        }
        .padding(.horizontal, SVSpacing.xl)
    }

    private var sortedTasks: [SyncTask] {
        let onDemand = appState.syncTasks.filter { $0.mode == .onDemand }
        let folders = appState.syncTasks.filter { $0.mode != .onDemand }
            .sorted { $0.localPath < $1.localPath }
        return onDemand + folders
    }

    private func syncTaskRow(_ task: SyncTask) -> some View {
        HStack(spacing: 10) {
            SVChip(variant: task.mode == .onDemand ? .cloud : .folder)
            Text(taskDisplayName(task)).font(SVFont.body(12.5))
            Spacer()
            SVStatusPill(text: pillText(task), kind: pillKind(task))
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            if task.mode == .onDemand {
                openCloudDrive()
            } else {
                openTaskFolder(task)
            }
        }
    }

    private func taskDisplayName(_ task: SyncTask) -> String {
        URL(fileURLWithPath: task.localPath).lastPathComponent
    }

    private func pillKind(_ task: SyncTask) -> SVStatusPill.Kind {
        if task.mode == .onDemand { return .cloud }
        if !task.isEnabled { return .paused }
        return .neutral
    }

    private func pillText(_ task: SyncTask) -> String {
        if task.mode == .onDemand { return "on-demand" }
        if !task.isEnabled { return "paused" }
        return "synced"
    }

    private var syncedCount: Int {
        appState.syncTasks.filter { $0.isEnabled }.count
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack {
            Text("v\(Bundle.main.shortVersion)").font(SVFont.mono(10))
            Spacer()
            Text(uptimeFormatted).font(SVFont.mono(10))
        }
        .foregroundStyle(SVColor.textTertiary)
        .padding(.horizontal, SVSpacing.xl)
        .padding(.top, SVSpacing.m)
        .padding(.bottom, 2)
    }

    private var uptimeFormatted: String {
        ""
    }

    // MARK: - Actions

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Update notification — 3 states: available → downloading (with %) → ready to install
            if let version = updaterService.availableVersion {
                if updaterService.downloadedDMG != nil {
                    actionRow(icon: "checkmark.circle.fill", label: "Quit & Install v\(version)", color: .green) {
                        updaterService.quitAndInstall()
                    }
                } else if updaterService.isDownloading {
                    // Compact inline progress so it doesn't dominate the menu
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 13))
                            .foregroundColor(.accentColor)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Downloading v\(version)…")
                                .font(.system(size: 12))
                            ProgressView(value: updaterService.downloadProgress)
                                .progressViewStyle(.linear)
                        }
                        Text("\(Int(updaterService.downloadProgress * 100))%")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                } else {
                    actionRow(icon: "arrow.down.circle.fill", label: "Update to v\(version)", color: .orange) {
                        updaterService.openUpdateWindow()
                    }
                }
            }

            // Open on Server first — primary outbound action, sits closest to the eye.
            actionRow(icon: "globe", label: "Open on Server", color: .blue) {
                let baseURL = appState.serverURL.isEmpty ? "https://sync.heesakkers.com" : appState.serverURL
                if let token = KeychainHelper.load(key: "access_token"),
                   let url = URL(string: "\(baseURL)/api/auth/auto-login?token=\(token)") {
                    NSWorkspace.shared.open(url)
                } else if let url = URL(string: "\(baseURL)/files") {
                    NSWorkspace.shared.open(url)
                }
            }

            // Point-in-time restore browser — Synology Drive-style window with
            // folder tree, snapshot file list, and a strip of restore points
            // along the bottom.
            actionRow(icon: "clock.arrow.circlepath", label: "Restore Files…") {
                NotificationCenter.default.post(name: .openRestoreFilesWindow, object: nil)
            }
            // NOTE: TrashView, the "trash" Window scene, and the API methods
            // are kept (cheap to retain, occasionally useful). Only the menu
            // bar row is removed — once the versioning bug was fixed the trash
            // stopped filling up with garbage and routine cleanup isn't needed
            // anymore. Web UI handles the rare restore case.

            // Single dynamic row: Pause while syncing, Continue while paused,
            // Sync Now when idle. Saves a row and tells the user exactly what
            // tapping it will do right now.
            if appState.isSyncing {
                actionRow(icon: "pause.fill", label: "Pause Sync") {
                    appState.togglePause()
                }
                .opacity(appState.isConnected ? 1 : 0.4)
            } else if appState.isPaused {
                actionRow(icon: "play.fill", label: "Continue Sync", color: .blue) {
                    appState.togglePause()
                }
                .opacity(appState.isConnected ? 1 : 0.4)
            } else {
                actionRow(icon: "arrow.triangle.2.circlepath", label: "Sync Now") {
                    Task { await appState.runSync() }
                }
                .opacity(appState.isConnected ? 1 : 0.4)
            }

            // Settings + version on same line
            HStack {
                SettingsLink {
                    HStack(spacing: 8) {
                        Image(systemName: "gear")
                            .font(.system(size: 11))
                            .frame(width: 14)
                        Text("Settings...")
                            .font(.system(size: 12))
                    }
                    .foregroundColor(.primary)
                    .contentShape(Rectangle())
                    .padding(.vertical, 3)
                }
                .buttonStyle(.plain)
                .simultaneousGesture(TapGesture().onEnded {
                    NSApp.activate(ignoringOtherApps: true)
                    for window in NSApp.windows where window.title.contains("Settings") || window.title.contains("SyncVault") {
                        if window.isVisible { window.makeKeyAndOrderFront(nil) }
                    }
                    // Hide (not close!) the MenuBarExtra popover so the user isn't
                    // staring at two overlapping UIs. orderOut keeps the window
                    // instance alive — close() permanently breaks future taps.
                    // Match only the MenuBarExtra class so we never accidentally
                    // hide settings or other system panels.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        for window in NSApp.windows {
                            if window.className.contains("MenuBarExtra") {
                                window.orderOut(nil)
                            }
                        }
                    }
                })

                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Reusable Components

    private var subtleDivider: some View {
        Divider().opacity(0.3)
    }

    private func menuSectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(Color(white: 0.4))
            .tracking(0.5)
    }

    private func actionRow(icon: String, label: String, color: Color = .primary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .frame(width: 14)
                Text(label)
                    .font(.system(size: 12))
            }
            .foregroundColor(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private var serverDisplayURL: String {
        appState.serverURL
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
    }

    func taskStatusColor(_ task: SyncTask) -> Color {
        if !task.isEnabled { return Color(white: 0.35) }
        if task.mode == .onDemand { return .blue }
        if appState.isSyncing && appState.activeSyncTaskName == task.remoteFolderName { return .blue }
        return Color.green
    }

    func taskStatusLabel(_ task: SyncTask) -> String {
        if !task.isEnabled { return "paused" }
        if task.mode == .onDemand { return "on-demand" }
        if appState.isSyncing && appState.activeSyncTaskName == task.remoteFolderName { return "syncing" }
        return "synced"
    }

    func fileTypeIcon(for filename: String) -> (symbol: String, color: Color) {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "js", "ts", "swift", "py", "go", "json", "html", "css", "md", "txt", "xml", "yaml", "yml":
            return ("doc.text", .blue)
        case "jpg", "jpeg", "png", "gif", "tiff", "bmp", "svg", "webp", "heic":
            return ("photo", .green)
        case "psd", "psb", "ai", "eps", "indd", "sketch", "fig":
            return ("paintbrush", .purple)
        case "mp4", "mov", "avi", "mkv", "m4v", "wmv", "flv", "webm":
            return ("film", .pink)
        case "wav", "mp3", "aif", "aiff", "m4a", "flac", "ogg", "aac":
            return ("music.note", .red)
        case "pdf":
            return ("doc.richtext", .red)
        case "doc", "docx", "rtf", "pages":
            return ("doc.richtext", .blue)
        case "xls", "xlsx", "csv", "tsv", "numbers":
            return ("tablecells", .green)
        case "ppt", "pptx", "key":
            return ("rectangle.fill.on.rectangle.fill", .orange)
        case "zip", "rar", "7z", "tar", "gz", "dmg":
            return ("shippingbox", .brown)
        case "aep", "prproj", "drp", "mogrt", "aepx":
            return ("gearshape.2", .purple)
        default:
            return ("doc", .secondary)
        }
    }

    func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    func formatSpeed(_ bytesPerSecond: Double) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return "\(formatter.string(fromByteCount: Int64(bytesPerSecond)))/s"
    }

    func timeAgo(_ date: Date) -> String {
        let seconds = Int(-date.timeIntervalSinceNow)
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86400)d"
    }

    private func debugLog(_ msg: String) {
        let path = NSHomeDirectory() + "/syncvault-debug.log"
        let line = "\(Date()): \(msg)\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            handle.closeFile()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    func openTaskFolder(_ task: SyncTask) {
        debugLog("openTaskFolder: \(task.localPath)")
        if let url = appState.resolveBookmark(for: task.localPath) {
            debugLog(" Bookmark resolved: \(url.path)")
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                url.stopAccessingSecurityScopedResource()
            }
        } else {
            debugLog(" No bookmark, trying direct: \(task.localPath)")
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: task.localPath)
        }
    }

    func openCloudDrive() {
        // Sandboxed apps cannot access ~/Library/CloudStorage directly.
        // Use /usr/bin/open which runs outside the sandbox and can open any Finder path.
        let realHome = FileManager.default.homeDirectoryForCurrentUser.path
            .replacingOccurrences(of: "/Library/Containers/com.syncvault.app/Data", with: "")
        let names = ["SyncVault-SyncVault-\(appState.username)", "SyncVault-CloudDrive", "SyncVault-SyncVault"]
        for name in names {
            let path = "\(realHome)/Library/CloudStorage/\(name)"
            debugLog(" openCloudDrive: trying \(path)")
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            proc.arguments = [path]
            try? proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus == 0 {
                debugLog(" openCloudDrive: opened \(path)")
                return
            }
        }
        debugLog(" openCloudDrive: fallback")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = ["\(realHome)/Library/CloudStorage"]
        try? proc.run()
    }

    func openRecentFile(_ item: ActivityItem) {
        debugLog(" openRecentFile: filename=\(item.filename) localPath=\(item.localPath) relativePath=\(item.relativePath)")
        for task in appState.syncTasks where task.isEnabled && task.mode != .onDemand {
            if let taskURL = appState.resolveBookmark(for: task.localPath) {
                // Try direct paths first
                let relPath = item.relativePath.isEmpty ? item.filename : item.relativePath
                let fullPath = (task.localPath as NSString).appendingPathComponent(relPath)
                if !item.localPath.isEmpty && FileManager.default.fileExists(atPath: item.localPath) {
                    debugLog(" Found at localPath: \(item.localPath)")
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.localPath)])
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { taskURL.stopAccessingSecurityScopedResource() }
                    return
                }
                if FileManager.default.fileExists(atPath: fullPath) {
                    debugLog(" Found at fullPath: \(fullPath)")
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: fullPath)])
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { taskURL.stopAccessingSecurityScopedResource() }
                    return
                }
                // Recursive search: find the file anywhere in the task folder
                if let found = findFile(named: item.filename, in: task.localPath) {
                    debugLog(" Found recursively: \(found)")
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: found)])
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { taskURL.stopAccessingSecurityScopedResource() }
                    return
                }
                taskURL.stopAccessingSecurityScopedResource()
            }
        }
        debugLog(" No file found for \(item.filename)")
    }

    private func findFile(named filename: String, in directory: String) -> String? {
        let enumerator = FileManager.default.enumerator(atPath: directory)
        while let path = enumerator?.nextObject() as? String {
            if (path as NSString).lastPathComponent == filename {
                return (directory as NSString).appendingPathComponent(path)
            }
        }
        return nil
    }
}

// MARK: - Team Invite Row

struct TeamInviteRow: View {
    let invite: AppNotification
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "person.3.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.blue)
                Text(invite.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            Text(invite.message)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(2)

            HStack(spacing: 8) {
                Button("Accept") { handleAccept() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                Button("Decline") {
                    Task { await appState.declineTeamInvite(notificationId: invite.id) }
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
        }
        .padding(8)
        .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.blue.opacity(0.15), lineWidth: 0.5))
    }

    private func handleAccept() {
        let (teamId, teamName) = parseInviteData(invite.data)
        let panel = NSOpenPanel()
        panel.title = "Choose local folder for \"\(teamName)\""
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let localFolder = panel.url else { return }
        Task {
            await appState.acceptTeamInvite(
                notificationId: invite.id, teamId: teamId,
                teamName: teamName, localFolder: localFolder
            )
        }
    }

    private func parseInviteData(_ data: String?) -> (id: String, name: String) {
        guard let data = data else { return (id: invite.id, name: invite.title) }
        var teamId = invite.id
        var teamName = invite.title
        for part in data.split(separator: ",") {
            let kv = part.split(separator: ":", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let key = String(kv[0]).trimmingCharacters(in: .whitespaces)
            let value = String(kv[1]).trimmingCharacters(in: .whitespaces)
            if key == "team_id" { teamId = value }
            if key == "team_name" { teamName = value }
        }
        return (id: teamId, name: teamName)
    }
}

extension Bundle {
    var shortVersion: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }
}
