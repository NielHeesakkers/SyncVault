import SwiftUI
import AppKit

struct MenuBarView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var updaterService: UpdaterService

    var pendingInvites: [AppNotification] {
        appState.notifications.filter { $0.type == "team_invite" && !$0.acted }
    }

    var activeTasks: Int {
        appState.syncTasks.filter { $0.isEnabled }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // MARK: - Header: Connection status
            sectionView {
                HStack(spacing: 8) {
                    Circle()
                        .fill(appState.isConnected ? Color.green : Color(white: 0.4))
                        .frame(width: 8, height: 8)
                    Text(appState.isConnected ? "Connected" : "Disconnected")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary)
                    Spacer()
                    if appState.unreadCount > 0 {
                        Text("\(min(appState.unreadCount, 99))")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 16, height: 16)
                            .background(Color.red, in: Circle())
                    }
                }
                if appState.isConnected {
                    Text(appState.serverURL.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: ""))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }

            if appState.isConnected {
                divider

                // MARK: - Sync Progress
                sectionView {
                    if let progress = appState.syncProgress {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 10))
                                .foregroundColor(.blue)
                                .rotationEffect(.degrees(appState.isSyncing ? 360 : 0))
                                .animation(.linear(duration: 2).repeatForever(autoreverses: false), value: appState.isSyncing)
                            Text("\(progress.action) \(progress.currentFile)")
                                .font(.system(size: 11))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text("\(progress.filesCompleted + 1)/\(progress.filesTotal)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        ProgressView(value: Double(progress.filesCompleted), total: Double(max(progress.filesTotal, 1)))
                            .tint(.blue)
                            .scaleEffect(y: 0.6)
                        if progress.bytesPerSecond > 0 {
                            HStack {
                                Spacer()
                                Text(formatSpeed(progress.bytesPerSecond))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        }
                    } else {
                        HStack(spacing: 6) {
                            Image(systemName: appState.isSyncing ? "arrow.triangle.2.circlepath" : "checkmark")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(appState.isSyncing ? .blue : .green)
                            Text(appState.isSyncing ? "Syncing..." : "Up to date")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }

                    if let error = appState.lastError {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.orange)
                            Text(error)
                                .font(.system(size: 10))
                                .foregroundColor(.orange)
                                .lineLimit(2)
                        }
                        .padding(.top, 2)
                    }
                }

                // MARK: - Team Invites
                if !pendingInvites.isEmpty {
                    divider
                    sectionView {
                        ForEach(pendingInvites) { invite in
                            TeamInviteRow(invite: invite, appState: appState)
                        }
                    }
                }

                // MARK: - Sync Queue
                if let progress = appState.syncProgress, progress.filesTotal > 0 {
                    divider
                    sectionView {
                        HStack {
                            sectionHeader("Sync Queue")
                            Spacer()
                            Text("\(progress.filesCompleted)/\(progress.filesTotal)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        ForEach(appState.syncQueue.prefix(5), id: \.self) { filename in
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 10))
                                    .foregroundColor(.blue)
                                    .frame(width: 14)
                                Text(filename)
                                    .font(.system(size: 11))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Text("pending")
                                    .font(.system(size: 10))
                                    .foregroundColor(Color(white: 0.4))
                            }
                            .padding(.vertical, 1)
                        }
                    }
                }

                divider

                // MARK: - Sync Tasks + Storage
                sectionView {
                    HStack {
                        sectionHeader("Sync Tasks")
                        Spacer()
                        Text("\(activeTasks) / \(appState.syncTasks.count)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    ForEach(appState.syncTasks) { task in
                        HStack(spacing: 8) {
                            Text(task.remoteFolderName)
                                .font(.system(size: 11))
                                .lineLimit(1)
                            Spacer()
                            Circle()
                                .fill(taskStatusColor(task))
                                .frame(width: 6, height: 6)
                            Text(taskStatusLabel(task))
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .frame(width: 55, alignment: .trailing)
                        }
                        .padding(.vertical, 1)
                    }

                    if appState.storageTotal > 0 {
                        Spacer().frame(height: 8)
                        sectionHeader("Storage")
                        GeometryReader { geo in
                            let fraction = min(Double(appState.storageUsed) / Double(max(appState.storageTotal, 1)), 1.0)
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color(white: 0.2))
                                    .frame(height: 6)
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(fraction > 0.9 ? Color.red : fraction > 0.7 ? Color.orange : Color.blue)
                                    .frame(width: geo.size.width * fraction, height: 6)
                            }
                        }
                        .frame(height: 6)
                        HStack {
                            Spacer()
                            Text("\(formatBytes(appState.storageUsed)) / \(formatBytes(appState.storageTotal))")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }

            divider

            // MARK: - Actions
            sectionView {
                // Update notification
                if let version = updaterService.availableVersion {
                    actionRow(icon: "arrow.down.circle.fill", label: "Update to v\(version)", color: .orange) {
                        updaterService.downloadAndInstallUpdate(version: version)
                    }
                    .disabled(updaterService.isDownloading)

                    if updaterService.isDownloading {
                        HStack(spacing: 6) {
                            ProgressView()
                                .scaleEffect(0.5)
                                .frame(width: 14, height: 14)
                            Text("Downloading...")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 1)
                    }
                }

                actionRow(icon: "arrow.triangle.2.circlepath", label: "Sync Now") {
                    Task { await appState.runSync() }
                }
                .opacity(appState.isConnected && !appState.isSyncing ? 1 : 0.4)

                actionRow(icon: "globe", label: "Open Files on Server") {
                    let baseURL = appState.serverURL.isEmpty ? "https://sync.heesakkers.com" : appState.serverURL
                    if let token = KeychainHelper.load(key: "access_token"),
                       let url = URL(string: "\(baseURL)/api/auth/auto-login?token=\(token)") {
                        NSWorkspace.shared.open(url)
                    } else if let url = URL(string: "\(baseURL)/files") {
                        NSWorkspace.shared.open(url)
                    }
                }

                if updaterService.availableVersion == nil {
                    actionRow(icon: "arrow.clockwise", label: "Check for Updates") {
                        updaterService.checkForUpdates()
                    }
                }

                SettingsLink {
                    HStack(spacing: 8) {
                        Image(systemName: "gear")
                            .font(.system(size: 11))
                            .frame(width: 14)
                        Text("Settings...")
                            .font(.system(size: 12))
                    }
                    .foregroundColor(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .padding(.vertical, 3)
                }
                .buttonStyle(.plain)

                actionRow(icon: "power", label: "Quit", color: Color(white: 0.5)) {
                    NSApplication.shared.terminate(nil)
                }
            }

            // Version footer
            HStack {
                Spacer()
                Text("v\(appVersion)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(Color(white: 0.35))
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
            .padding(.top, 2)
        }
        .frame(width: 300)
    }

    // MARK: - Reusable Components

    private func sectionView<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            content()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color(white: 0.2))
            .frame(height: 0.5)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(Color(white: 0.45))
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

    func taskStatusColor(_ task: SyncTask) -> Color {
        if !task.isEnabled { return Color(white: 0.35) }
        if task.mode == .onDemand { return .purple }
        return appState.isSyncing ? Color.blue : Color.green
    }

    func taskStatusLabel(_ task: SyncTask) -> String {
        if !task.isEnabled { return "paused" }
        if task.mode == .onDemand { return "on-demand" }
        return appState.isSyncing ? "syncing" : "idle"
    }

    func iconForAction(_ action: String) -> String {
        switch action {
        case "uploaded": return "arrow.up"
        case "downloaded": return "arrow.down"
        case "deleted": return "xmark"
        default: return "doc"
        }
    }

    func colorForAction(_ action: String) -> Color {
        switch action {
        case "uploaded": return .blue
        case "downloaded": return .green
        case "deleted": return Color(white: 0.5)
        default: return .secondary
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
