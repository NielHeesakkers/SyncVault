import SwiftUI

struct MenuBarIcon: View {
    let isSyncing: Bool
    let isConnected: Bool

    @State private var blinkPhase = false

    var body: some View {
        Image(systemName: iconName)
            .symbolRenderingMode(.palette)
            .foregroundStyle(iconColor)
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
