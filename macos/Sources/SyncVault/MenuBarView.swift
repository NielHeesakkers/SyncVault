import SwiftUI

struct MenuBarView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var updaterService: UpdaterService

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
            }

            if appState.isConnected {
                // Sync status
                HStack {
                    Image(systemName: appState.menuBarIcon)
                    Text(appState.isSyncing ? "Syncing..." : "Up to date")
                        .foregroundColor(.secondary)
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

            // Actions
            Button("Sync Now") {
                // Trigger manual sync
            }
            .disabled(!appState.isConnected)

            SettingsLink {
                Text("Settings...")
            }
            .keyboardShortcut(",", modifiers: .command)

            Button("Check for Updates...") {
                updaterService.checkForUpdates()
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
}
