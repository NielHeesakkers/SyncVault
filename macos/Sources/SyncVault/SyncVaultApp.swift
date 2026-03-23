import SwiftUI

@main
struct SyncVaultApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var updaterService = UpdaterService()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(appState: appState, updaterService: updaterService)
        } label: {
            Image(systemName: appState.isSyncing ? "arrow.triangle.2.circlepath.icloud" :
                    appState.isConnected ? "checkmark.icloud" : "cloud.slash")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(appState: appState, updaterService: updaterService)
        }
    }
}
