import SwiftUI

@main
struct SyncVaultApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var updaterService = UpdaterService()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(appState: appState, updaterService: updaterService)
        } label: {
            Label("SyncVault", systemImage: appState.menuBarIcon)
                .labelStyle(.iconOnly)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(appState: appState, updaterService: updaterService)
        }
    }
}
