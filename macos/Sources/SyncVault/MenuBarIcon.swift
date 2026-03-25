import SwiftUI

struct MenuBarIcon: View {
    let isSyncing: Bool
    let isConnected: Bool
    var syncProgress: SyncProgress? = nil

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: iconName)
                .symbolRenderingMode(.palette)
                .foregroundStyle(iconColor)
            if isSyncing, let progress = syncProgress, progress.bytesPerSecond > 100 {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 2) {
                        Text("↑")
                            .foregroundColor(.green)
                        Text(formatSpeed(progress.bytesPerSecond))
                            .foregroundColor(.green)
                    }
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                }
            }
        }
    }

    private func formatSpeed(_ bps: Double) -> String {
        if bps > 1_000_000 { return String(format: "%.1f MB/s", bps / 1_000_000) }
        if bps > 1_000 { return String(format: "%.0f KB/s", bps / 1_000) }
        return String(format: "%.0f B/s", bps)
    }

    private var iconName: String {
        if !isConnected { return "icloud.slash" }
        if isSyncing { return "arrow.triangle.2.circlepath.icloud" }
        return "checkmark.icloud"
    }

    private var iconColor: Color {
        if !isConnected { return .gray }
        if isSyncing { return .blue }
        return .green
    }
}
