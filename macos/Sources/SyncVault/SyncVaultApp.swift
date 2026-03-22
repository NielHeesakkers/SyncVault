import SwiftUI

@main
struct SyncVaultApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var updaterService = UpdaterService()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(appState: appState, updaterService: updaterService)
        } label: {
            ZStack(alignment: .topTrailing) {
                Label("SyncVault", systemImage: appState.menuBarIcon)
                    .labelStyle(.iconOnly)
                if appState.unreadCount > 0 {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                        .offset(x: 4, y: -4)
                }
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(appState: appState, updaterService: updaterService)
        }
    }
}
