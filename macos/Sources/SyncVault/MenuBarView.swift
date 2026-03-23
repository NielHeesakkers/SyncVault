import SwiftUI
import AppKit

struct MenuBarView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var updaterService: UpdaterService

    // Pending team invite notifications (type == "team_invite" and not yet acted on)
    var pendingInvites: [AppNotification] {
        appState.notifications.filter { $0.type == "team_invite" && !$0.acted }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Connection status
            HStack {
                Circle()
                    .fill(appState.isConnected ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(appState.isConnected ? "Connected" : "Disconnected")
                    .font(.headline)
                Spacer()
                if appState.unreadCount > 0 {
                    ZStack {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 18, height: 18)
                        Text("\(min(appState.unreadCount, 99))")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
            }

            if appState.isConnected {
                // Sync status with progress
                if let progress = appState.syncProgress {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .foregroundColor(.blue)
                                .rotationEffect(.degrees(appState.isSyncing ? 360 : 0))
                            Text("\(progress.action) (\(progress.filesCompleted + 1)/\(progress.filesTotal))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Text(progress.currentFile)
                            .font(.caption2)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if progress.bytesPerSecond > 0 {
                            Text(formatSpeed(progress.bytesPerSecond))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                } else {
                    HStack {
                        Image(systemName: appState.isSyncing ? "arrow.triangle.2.circlepath" : "checkmark.circle")
                            .foregroundColor(appState.isSyncing ? .blue : .green)
                        Text(appState.isSyncing ? "Syncing..." : "Up to date")
                            .foregroundColor(.secondary)
                    }
                }

                if let error = appState.lastError {
                    HStack {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundColor(.orange)
                        Text(error)
                            .font(.caption2)
                            .foregroundColor(.orange)
                            .lineLimit(2)
                    }
                }

                // Team folder invites
                if !pendingInvites.isEmpty {
                    Divider()

                    Text("Team Folder Invites")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    ForEach(pendingInvites) { invite in
                        TeamInviteRow(invite: invite, appState: appState)
                    }
                }

                Divider()

                // Recent activity
                if !appState.recentActivity.isEmpty {
                    Text("Recent Activity")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    ForEach(appState.recentActivity.prefix(5)) { item in
                        HStack {
                            Image(systemName: iconForAction(item.action))
                                .foregroundColor(.blue)
                                .frame(width: 16)
                            Text(item.filename)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(item.timestamp, style: .relative)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .font(.caption)
                    }
                }

                Divider()

                // Storage
                if appState.storageTotal > 0 {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Storage")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        ProgressView(value: Double(appState.storageUsed), total: Double(appState.storageTotal))
                        Text("\(formatBytes(appState.storageUsed)) of \(formatBytes(appState.storageTotal))")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Divider()

            // Version
            Text("SyncVault v\(appVersion)")
                .font(.caption2)
                .foregroundColor(.secondary)

            Divider()

            // Actions
            Button("Sync Now") {
                Task { await appState.runSync() }
            }
            .disabled(!appState.isConnected || appState.isSyncing)

            SettingsLink {
                Text("Settings...")
            }
            .keyboardShortcut(",", modifiers: .command)

            if let version = updaterService.availableVersion {
                Button {
                    updaterService.downloadAndInstallUpdate(version: version)
                } label: {
                    HStack {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundColor(.orange)
                        Text("Update to v\(version)")
                            .foregroundColor(.orange)
                    }
                }
                .disabled(updaterService.isDownloading)
            } else {
                Button("Check for Updates...") {
                    updaterService.checkForUpdates()
                }
            }

            if updaterService.isDownloading {
                HStack {
                    ProgressView()
                        .scaleEffect(0.6)
                    Text("Downloading...")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Divider()

            Button("Quit SyncVault") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .padding()
        .frame(width: 280)
    }

    func iconForAction(_ action: String) -> String {
        switch action {
        case "uploaded": return "arrow.up.circle"
        case "downloaded": return "arrow.down.circle"
        case "deleted": return "trash"
        default: return "doc"
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
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "person.3")
                    .foregroundColor(.blue)
                Text(invite.title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)
            }
            Text(invite.message)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(2)

            HStack(spacing: 8) {
                Button("Accept") {
                    handleAccept()
                }
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
        .background(Color.blue.opacity(0.05))
        .cornerRadius(6)
    }

    private func handleAccept() {
        // Parse the team id from the notification data field ("team_id:<id>|team_name:<name>")
        // data format is expected as "team_id:<id>" or JSON — we use a simple convention
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
                notificationId: invite.id,
                teamId: teamId,
                teamName: teamName,
                localFolder: localFolder
            )
        }
    }

    private func parseInviteData(_ data: String?) -> (id: String, name: String) {
        // Expected data format: "team_id:<id>,team_name:<name>"
        // Falls back to the notification title if parsing fails.
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
