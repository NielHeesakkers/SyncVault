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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // MARK: - Header: Status
            statusHeader
            subtleDivider

            if appState.isConnected {
                // MARK: - Recently Changed
                if !appState.recentActivity.isEmpty {
                    recentlyChangedSection
                    subtleDivider
                }

                // MARK: - Backup Tasks
                if hasBackupTasks {
                    backupTasksSection
                    subtleDivider
                }

                // MARK: - CloudDrive (on-demand)
                if hasOnDemandTasks {
                    cloudDriveSection
                    subtleDivider
                }
            }

            // MARK: - Actions
            actionsSection

            // Version (inline with bottom)
            HStack {
                Spacer()
                Text("v\(appVersion)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Color(white: 0.4))
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 6)
        }
        .frame(width: 300)
    }

    // MARK: - Status Header

    private var statusHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !appState.isConnected {
                // Disconnected
                HStack(spacing: 10) {
                    Image(systemName: "xmark.icloud")
                        .font(.system(size: 20))
                        .foregroundColor(Color(white: 0.4))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Disconnected")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.primary)
                    }
                }
            } else if appState.isPaused {
                // Paused
                HStack(spacing: 10) {
                    Image(systemName: "pause.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(Color(white: 0.4))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Paused")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.primary)
                        Text(serverDisplayURL)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
            } else if let error = appState.lastError {
                // Error
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Warning")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.orange)
                        Text(error)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                }
            } else if let progress = appState.syncProgress {
                // Syncing with progress
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 20))
                            .foregroundColor(.blue)
                            .rotationEffect(.degrees(appState.isSyncing ? 360 : 0))
                            .animation(.linear(duration: 2).repeatForever(autoreverses: false), value: appState.isSyncing)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 4) {
                                Text("Syncing")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.primary)
                                if let taskName = appState.activeSyncTaskName {
                                    Text("— \(taskName)")
                                        .font(.system(size: 13))
                                        .foregroundColor(.secondary)
                                }
                            }
                            HStack(spacing: 4) {
                                Text(progress.currentFile)
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                if progress.bytesPerSecond > 100 {
                                    Text("·")
                                        .foregroundColor(Color(white: 0.4))
                                    Text(formatSpeed(progress.bytesPerSecond))
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(.blue)
                                }
                            }
                        }
                        Spacer()
                        Text("\(progress.filesCompleted)/\(progress.filesTotal)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(Color(white: 0.4))
                    }

                    // Progress bar
                    if progress.totalBytes > 0 {
                        VStack(spacing: 3) {
                            ProgressView(value: Double(progress.bytesTransferred), total: Double(max(progress.totalBytes, 1)))
                                .tint(.blue)
                                .scaleEffect(y: 0.6)
                            HStack {
                                Spacer()
                                Text("\(formatBytes(progress.bytesTransferred)) / \(formatBytes(progress.totalBytes))")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(Color(white: 0.4))
                            }
                        }
                    }
                }

                // FileProvider on-demand progress is shown inline in the Sync Tasks section
            } else if appState.isSyncing {
                // Syncing without detailed progress
                HStack(spacing: 10) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 20))
                        .foregroundColor(.blue)
                        .rotationEffect(.degrees(360))
                        .animation(.linear(duration: 2).repeatForever(autoreverses: false), value: appState.isSyncing)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Syncing...")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.primary)
                        Text(serverDisplayURL)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
            } else {
                // Up to date
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.green)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Up to date")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.primary)
                        Text(serverDisplayURL)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - Recently Changed

    private var recentlyChangedSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            menuSectionHeader("Recently Changed")

            ForEach(Array(appState.recentActivity.prefix(5))) { item in
                Button(action: { openRecentFile(item) }) {
                    HStack(spacing: 8) {
                        let icon = fileTypeIcon(for: item.filename)
                        Image(systemName: icon.symbol)
                            .font(.system(size: 12))
                            .foregroundColor(icon.color)
                            .frame(width: 16)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.filename)
                                .font(.system(size: 11))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundColor(.primary)

                            HStack(spacing: 0) {
                                if !item.taskName.isEmpty {
                                    Text(item.taskName)
                                        .foregroundColor(.secondary)
                                    Text(" · ")
                                        .foregroundColor(Color(white: 0.35))
                                }
                                Text(item.action.capitalized)
                                    .foregroundColor(.secondary)
                                Text(" · ")
                                    .foregroundColor(Color(white: 0.35))
                                Text(timeAgo(item.timestamp))
                                    .foregroundColor(Color(white: 0.4))
                            }
                            .font(.system(size: 10))
                        }

                        Spacer()
                    }
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - CloudDrive Section

    private var cloudDriveSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            menuSectionHeader("CloudDrive")

            ForEach(onDemandTasks) { task in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Image(systemName: "icloud.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.blue)
                            .frame(width: 16)
                        Text(task.remoteFolderName)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                        Spacer()
                        if appState.fpProgress != nil {
                            Image(systemName: "arrow.up.arrow.down")
                                .font(.system(size: 9))
                                .foregroundColor(.blue)
                        } else {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9))
                                .foregroundColor(Color(white: 0.4))
                        }
                    }

                    // FileProvider activity
                    if let fpStatus = appState.fpProgress {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(fpStatus)
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                if appState.fpSpeed > 100 {
                                    Text(formatSpeed(appState.fpSpeed))
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(.blue)
                                }
                            }
                        }
                        .padding(.leading, 24)
                    } else {
                        Text("Available in Finder")
                            .font(.system(size: 10))
                            .foregroundColor(Color(white: 0.4))
                            .padding(.leading, 24)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Backup Tasks

    private var backupTasksSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                menuSectionHeader("Backup Tasks")
                Spacer()
                let activeBackup = backupTasks.filter { $0.isEnabled }.count
                Text("\(activeBackup) / \(backupTasks.count)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Color(white: 0.4))
            }

            ForEach(backupTasks) { task in
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                        .frame(width: 14)
                    Text(task.remoteFolderName)
                        .font(.system(size: 11))
                        .lineLimit(1)
                    Spacer()
                    Circle()
                        .fill(taskStatusColor(task))
                        .frame(width: 6, height: 6)
                    Text(taskStatusLabel(task))
                        .font(.system(size: 10))
                        .foregroundColor(Color(white: 0.4))
                        .frame(width: 55, alignment: .trailing)
                }
                .padding(.vertical, 1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Actions

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Update notification
            if let version = updaterService.availableVersion {
                actionRow(icon: "arrow.down.circle.fill", label: "Update to v\(version)", color: .orange) {
                    updaterService.downloadAndInstallUpdate(version: version)
                }
                .disabled(updaterService.isDownloading)
            }

            // Pause / Continue toggle
            actionRow(
                icon: appState.isPaused ? "play.fill" : "pause.fill",
                label: appState.isPaused ? "Continue Sync" : "Pause Sync",
                color: appState.isPaused ? .blue : .primary
            ) {
                appState.togglePause()
            }
            .opacity(appState.isConnected ? 1 : 0.4)

            // Sync Now
            actionRow(icon: "arrow.triangle.2.circlepath", label: "Sync Now") {
                Task { await appState.runSync() }
            }
            .opacity(appState.isConnected && !appState.isSyncing && !appState.isPaused ? 1 : 0.4)

            // Open on Server
            actionRow(icon: "globe", label: "Open on Server", color: .blue) {
                let baseURL = appState.serverURL.isEmpty ? "https://sync.heesakkers.com" : appState.serverURL
                if let token = KeychainHelper.load(key: "access_token"),
                   let url = URL(string: "\(baseURL)/api/auth/auto-login?token=\(token)") {
                    NSWorkspace.shared.open(url)
                } else if let url = URL(string: "\(baseURL)/files") {
                    NSWorkspace.shared.open(url)
                }
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
        return "idle"
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

    func openRecentFile(_ item: ActivityItem) {
        // Try localPath first (set during sync)
        if !item.localPath.isEmpty {
            let url = URL(fileURLWithPath: item.localPath)
            if FileManager.default.fileExists(atPath: item.localPath) {
                NSWorkspace.shared.open(url)
                return
            }
        }
        // Fallback: search in task folders
        for task in appState.syncTasks where task.isEnabled {
            let fullPath = (task.localPath as NSString).appendingPathComponent(item.filename)
            if FileManager.default.fileExists(atPath: fullPath) {
                NSWorkspace.shared.open(URL(fileURLWithPath: fullPath))
                return
            }
        }
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
