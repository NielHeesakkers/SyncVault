import SwiftUI

struct MenuBarIcon: View {
    let isSyncing: Bool
    let isConnected: Bool
    var syncProgress: SyncProgress? = nil

    @State private var blinkPhase = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: iconName)
                .symbolRenderingMode(.palette)
                .foregroundStyle(iconColor)
            if isSyncing, let progress = syncProgress, progress.bytesPerSecond > 0 {
                Text(formatSpeed(progress.bytesPerSecond))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(.green)
            }
        }
        .onChange(of: isSyncing) { _, syncing in
            if syncing {
                startBlinking()
            } else {
                blinkPhase = false
            }
        }
        .onAppear {
            if isSyncing { startBlinking() }
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
        if isSyncing { return blinkPhase ? .blue : .green }
        return .green
    }

    private func startBlinking() {
        Task { @MainActor in
            while isSyncing {
                withAnimation(.easeInOut(duration: 0.6)) {
                    blinkPhase.toggle()
                }
                try? await Task.sleep(nanoseconds: 600_000_000)
            }
            blinkPhase = false
        }
    }
}
