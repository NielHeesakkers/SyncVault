import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var updaterService: UpdaterService

    var body: some View {
        TabView {
            ConnectionTab(appState: appState)
                .tabItem { Label("Connection", systemImage: "network") }

            SyncTasksTab(appState: appState)
                .tabItem { Label("Sync Tasks", systemImage: "arrow.triangle.2.circlepath") }

            GeneralTab(updaterService: updaterService)
                .tabItem { Label("General", systemImage: "gear") }
        }
        .frame(width: 500, height: 400)
    }
}
